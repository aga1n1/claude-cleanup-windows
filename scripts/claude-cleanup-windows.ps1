#Requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('Audit','Apply')][string]$Mode = 'Audit',
    [string]$WorkDirectory = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ClaudeCleanup')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$stateRoot = [IO.Path]::GetFullPath($WorkDirectory)
$planPath = Join-Path $stateRoot 'plan.json'
$reportPath = Join-Path $stateRoot 'result.json'
$profileRoot = [Environment]::GetFolderPath('UserProfile')
$cliRoot = Join-Path $profileRoot '.claude'
$identityPath = Join-Path $profileRoot '.claude.json'
$desktopRoot = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Claude'
$allowlist = @()
foreach ($name in @('cache','stats-cache.json','telemetry','usage-data','usage.jsonl','usage.with-fix.jsonl')) {
    $allowlist += Join-Path $cliRoot $name
}
foreach ($name in @('Cache','Code Cache','GPUCache','DawnGraphiteCache','DawnWebGPUCache','logs')) {
    $allowlist += Join-Path $desktopRoot $name
}
$allowlist += Join-Path $profileRoot 'AppData\Local\claude-cli-nodejs'

function Get-ClaudeProcesses {
    # Only process metadata is inspected; command lines are never printed.
    $processes = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match 'claude' -or
        ($_.Name -match '^node(\.exe)?$' -and $_.CommandLine -match '(@anthropic-ai[\\/]claude-code|claude-code[\\/]|claude[\\/]cli\.js)')
    })
    $processes | Select-Object ProcessId, Name
}

function Assert-Idle {
    if (@(Get-ClaudeProcesses).Count -gt 0) { throw 'Claude processes are running. Exit Claude normally and audit again.' }
}

function Get-Snapshot([string]$Root) {
    $items = [Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $Root)) { return }
    $base = (Get-Item -LiteralPath $Root -Force).FullName
    $queue = [Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($base)
    while ($queue.Count -gt 0) {
        $item = Get-Item -LiteralPath $queue.Dequeue() -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point refused: $($item.FullName)" }
        $relative = $item.FullName.Substring($base.Length).TrimStart([char]'\')
        if ($item.PSIsContainer) {
            $items.Add([pscustomobject]@{Relative=$relative;Type='Directory';Bytes=0;SHA256=''})
            foreach ($child in (Get-ChildItem -LiteralPath $item.FullName -Force)) { $queue.Enqueue($child.FullName) }
        } else {
            $items.Add([pscustomobject]@{Relative=$relative;Type='File';Bytes=$item.Length;SHA256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash})
        }
    }
    $items | Sort-Object Relative
}

function Get-Fingerprint($Snapshot) {
    $json = ConvertTo-Json -InputObject @($Snapshot) -Depth 5 -Compress
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).Replace('-','') }
    finally { $hasher.Dispose() }
}

function Write-JsonFile([string]$Path, $Data) {
    $json = ConvertTo-Json -InputObject $Data -Depth 12
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function New-PrivateDirectory([string]$Path) {
    New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.SetOwner($currentSid)
    foreach ($sid in @($currentSid, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-ProtectedSnapshot($Root, $Targets) {
    @(Get-Snapshot $Root | Where-Object {
        $entry = $_
        $absolute = if ($entry.Relative) { Join-Path $Root $entry.Relative } else { $Root }
        $selected = $false
        foreach ($target in $Targets) {
            if ($absolute -eq $target -or $absolute.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase)) { $selected = $true; break }
        }
        -not $selected
    })
}

function Assert-WorkDirectory {
    if ($stateRoot.StartsWith('\\')) { throw 'WorkDirectory must be on a local drive.' }
    if ($stateRoot -eq [IO.Path]::GetPathRoot($stateRoot)) { throw 'WorkDirectory cannot be a drive root.' }
    foreach ($root in @($repositoryRoot, $profileRoot, $cliRoot, $desktopRoot)) {
        if ($stateRoot -eq $root -or $root.StartsWith($stateRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'WorkDirectory cannot contain the repository or Claude data.' }
    }
    foreach ($root in @($repositoryRoot, $cliRoot, $desktopRoot)) {
        if ($stateRoot.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'WorkDirectory must be outside the repository and Claude data.' }
    }
    $ancestor = $stateRoot
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'WorkDirectory cannot traverse a reparse point.' }
        }
        $ancestor = Split-Path -Parent $ancestor
    }
}

Assert-WorkDirectory
if ([Environment]::GetEnvironmentVariable('CLAUDE_CONFIG_DIR')) { throw 'Custom CLAUDE_CONFIG_DIR detected; default-path cleanup refused.' }
if (-not (Test-Path -LiteralPath $cliRoot -PathType Container)) { throw 'Cannot satisfy complete backup requirement: .claude is missing.' }
if ($Mode -eq 'Audit') {
    $processes = @(Get-ClaudeProcesses)
    $targets = @()
    foreach ($path in $allowlist) {
        if (Test-Path -LiteralPath $path) {
            $snapshot = @(Get-Snapshot $path)
            $files = @($snapshot | Where-Object Type -eq 'File')
            $bytes = [long]0
            foreach ($file in $files) { $bytes += $file.Bytes }
            $targets += [pscustomobject]@{Path=$path;Files=$files.Count;Bytes=$bytes;Fingerprint=(Get-Fingerprint $snapshot)}
        }
    }
    $cliSnapshot = @(Get-Snapshot $cliRoot)
    $identitySnapshot = @(Get-Snapshot $identityPath)
    $targetPaths = @($targets | ForEach-Object { $_.Path })
    $protectedCli = Get-ProtectedSnapshot $cliRoot $targetPaths
    $protectedDesktop = Get-ProtectedSnapshot $desktopRoot $targetPaths
    $plan = [pscustomobject]@{
        CreatedAt=(Get-Date).ToString('o'); Mode='Windows safe cache/log cleanup'; Targets=$targets
        CliRoot=$cliRoot; IdentityPath=$identityPath; DesktopRoot=$desktopRoot
        CliFingerprint=(Get-Fingerprint $cliSnapshot); IdentityFingerprint=(Get-Fingerprint $identitySnapshot)
        ProtectedCliFingerprint=(Get-Fingerprint $protectedCli); ProtectedDesktopFingerprint=(Get-Fingerprint $protectedDesktop)
        CliBackupBytes=[long](($cliSnapshot | Measure-Object Bytes -Sum).Sum)
        IdentityExists=(Test-Path -LiteralPath $identityPath -PathType Leaf)
        Processes=$processes.Count; IdentityRotation=$false; LoginReset=$false; Uninstall=$false; SettingsChange=$false; TimezoneChange=$false
    }
    if (-not (Test-Path -LiteralPath $stateRoot)) {
        New-PrivateDirectory $stateRoot
        [IO.File]::WriteAllText((Join-Path $stateRoot '.claude-cleanup-state'), 'claude-cleanup-windows')
    } elseif (-not (Test-Path -LiteralPath (Join-Path $stateRoot '.claude-cleanup-state') -PathType Leaf)) { throw 'Existing WorkDirectory is not a ClaudeCleanup state directory; choose a new directory.' }
    Write-JsonFile $planPath $plan
    $plan | ConvertTo-Json -Depth 8
    exit 0
}

# The reusable release requires the human to enter CONFIRM in a real terminal.
Assert-Idle
if (-not (Test-Path -LiteralPath (Join-Path $stateRoot '.claude-cleanup-state') -PathType Leaf)) { throw 'Run Audit first in a new, private WorkDirectory.' }
$plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
$targetPaths = @($plan.Targets | ForEach-Object { $_.Path })
if ($plan.CliRoot -ne $cliRoot -or $plan.IdentityPath -ne $identityPath -or $plan.DesktopRoot -ne $desktopRoot) { throw 'Audit belongs to a different user or environment.' }
if (@($plan.Targets).Count -eq 0) { Write-Output 'No cache/log targets found; nothing changed.'; exit 0 }
foreach ($target in $plan.Targets) {
    $absolute = [IO.Path]::GetFullPath($target.Path)
    if ($absolute -ne $target.Path -or $absolute -notin $allowlist) { throw "Target outside exact allowlist: $absolute" }
    if ((Get-Fingerprint @(Get-Snapshot $absolute)) -ne $target.Fingerprint) { throw "Target changed since audit: $absolute" }
}
$cliBefore = @(Get-Snapshot $cliRoot)
$identityBefore = @(Get-Snapshot $identityPath)
if ((Get-Fingerprint $cliBefore) -ne $plan.CliFingerprint -or (Get-Fingerprint $identityBefore) -ne $plan.IdentityFingerprint) { throw 'Claude data changed since audit; audit and approval must be repeated.' }
if ((Get-Fingerprint (Get-ProtectedSnapshot $cliRoot $targetPaths)) -ne $plan.ProtectedCliFingerprint) { throw 'Protected CLI data changed since audit.' }
if ((Get-Fingerprint (Get-ProtectedSnapshot $desktopRoot $targetPaths)) -ne $plan.ProtectedDesktopFingerprint) { throw 'Desktop persistent data changed since audit.' }
$requiredBytes = [long]$plan.CliBackupBytes + 104857600
foreach ($target in $plan.Targets) { $requiredBytes += [long]$target.Bytes }
if ((Get-PSDrive -Name ([IO.Path]::GetPathRoot($stateRoot).TrimEnd('\',':'))).Free -lt $requiredBytes) { throw 'Insufficient disk space for backup and quarantine.' }
Write-Output 'Final plan: full .claude/.claude.json backup; move only the following cache/log paths to quarantine:'
$plan.Targets | Select-Object Path, Files, Bytes | Format-Table -AutoSize | Out-Host
Write-Output 'Identity, login, sessions, projects, settings, telemetry configuration and timezone remain unchanged.'
if ([Console]::IsInputRedirected) { throw 'Apply requires an interactive terminal; piped confirmation is refused.' }
if ((Read-Host 'Type CONFIRM to execute this exact plan; any other input cancels') -cne 'CONFIRM') { Write-Output 'Cancelled; no Claude data changed.'; exit 1 }
Assert-Idle

$batch = Join-Path $stateRoot (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
New-PrivateDirectory $batch
$backup = Join-Path $batch 'backup'
New-Item -ItemType Directory -Path $backup | Out-Null
$moves = [Collections.Generic.List[object]]::new()
$result = [ordered]@{Status='Partial';Backup=$backup;Quarantine=(Join-Path $batch 'quarantine');Moves=$moves;Error=$null}
try {
    Copy-Item -LiteralPath $cliRoot -Destination (Join-Path $backup 'dot-claude') -Recurse -Force
    if ($plan.IdentityExists) { Copy-Item -LiteralPath $identityPath -Destination (Join-Path $backup 'claude.json') -Force }
    if ((Get-Fingerprint @(Get-Snapshot (Join-Path $backup 'dot-claude'))) -ne $plan.CliFingerprint) { throw 'Full .claude backup hash verification failed.' }
    if ((Get-Fingerprint @(Get-Snapshot $cliRoot)) -ne $plan.CliFingerprint) { throw '.claude changed during backup.' }
    if ($plan.IdentityExists -and (Get-Fingerprint @(Get-Snapshot (Join-Path $backup 'claude.json'))) -ne $plan.IdentityFingerprint) { throw '.claude.json backup hash verification failed.' }
    Write-JsonFile (Join-Path $backup 'manifest.json') $plan
    Assert-Idle
    New-Item -ItemType Directory -Path $result.Quarantine | Out-Null
    foreach ($target in $plan.Targets) {
        Assert-Idle
        if ((Get-Fingerprint @(Get-Snapshot $target.Path)) -ne $target.Fingerprint) { throw "Target changed before move: $($target.Path)" }
        $destination = Join-Path $result.Quarantine ('{0:D2}-{1}' -f $moves.Count, (Split-Path -Leaf $target.Path))
        Move-Item -LiteralPath $target.Path -Destination $destination -ErrorAction Stop
        $moves.Add([pscustomobject]@{Source=$target.Path;Destination=$destination;Bytes=$target.Bytes;Files=$target.Files})
        Write-JsonFile $reportPath $result
        if (Test-Path -LiteralPath $target.Path) { throw "Source still exists after move: $($target.Path)" }
        if ((Get-Fingerprint @(Get-Snapshot $destination)) -ne $target.Fingerprint) { throw "Quarantine verification failed: $destination" }
    }
    if ((Get-Fingerprint (Get-ProtectedSnapshot $cliRoot $targetPaths)) -ne $plan.ProtectedCliFingerprint) { throw 'Protected .claude data verification failed.' }
    if ((Get-Fingerprint (Get-ProtectedSnapshot $desktopRoot $targetPaths)) -ne $plan.ProtectedDesktopFingerprint) { throw 'Protected Desktop data verification failed.' }
    if ((Get-Fingerprint @(Get-Snapshot $identityPath)) -ne $plan.IdentityFingerprint) { throw 'Identity file changed.' }
    $result.Status = 'Complete'
} catch {
    $result.Error = $_.Exception.Message
    throw
} finally {
    Write-JsonFile $reportPath $result
    $result | ConvertTo-Json -Depth 8
}
