#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\claude-cleanup-windows.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$definitions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($definition in $definitions) { . ([scriptblock]::Create($definition.Extent.Text)) }

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Throws([scriptblock]$Action, [string]$Expected) {
    $caught = $false
    try { & $Action } catch {
        $caught = $true
        if ($_.Exception.Message -notlike "*$Expected*") { throw }
    }
    Assert-True $caught "Expected rejection: $Expected"
}

$fixtureRoot = Join-Path $PSScriptRoot ('.fixtures-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$junctionPath = Join-Path $fixtureRoot 'linked'
try {
    $profileRoot = Join-Path $fixtureRoot 'profile'
    $cliRoot = Join-Path $profileRoot '.claude'
    $desktopRoot = Join-Path $profileRoot 'Roaming\Claude'
    $repositoryRoot = Join-Path $fixtureRoot 'repository'
    $stateRoot = Join-Path $fixtureRoot 'private-state'
    foreach ($path in @((Join-Path $cliRoot 'cache'), (Join-Path $cliRoot 'empty'), $desktopRoot, $repositoryRoot)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    [IO.File]::WriteAllText((Join-Path $cliRoot 'cache\sample.txt'), 'cached data')
    [IO.File]::WriteAllText((Join-Path $cliRoot 'settings.json'), '{"env":{"DISABLE_TELEMETRY":"1"}}')
    [IO.File]::WriteAllText((Join-Path $cliRoot 'history.jsonl'), '{"message":"fixture"}')
    [IO.File]::WriteAllText((Join-Path $profileRoot '.claude.json'), '{"userID":"fixture-only"}')

    $snapshot = @(Get-Snapshot $cliRoot)
    Assert-True (@($snapshot | Where-Object { $_.Type -eq 'Directory' -and $_.Relative -eq 'empty' }).Count -eq 1) 'Empty directories must be recorded.'
    $before = Get-Fingerprint $snapshot
    $copyRoot = Join-Path $fixtureRoot 'copy'
    Copy-Item -LiteralPath $cliRoot -Destination $copyRoot -Recurse
    Assert-True ((Get-Fingerprint @(Get-Snapshot $copyRoot)) -eq $before) 'Verified backup must match.'
    [IO.File]::WriteAllText((Join-Path $copyRoot 'cache\sample.txt'), 'changed data')
    Assert-True ((Get-Fingerprint @(Get-Snapshot $copyRoot)) -ne $before) 'Same-length content changes must be detected.'
    Assert-True ((Get-Fingerprint @(Get-Snapshot (Join-Path $fixtureRoot 'missing'))) -eq (Get-Fingerprint @())) 'Missing target snapshot must be empty.'

    $targetPaths = @((Join-Path $cliRoot 'cache'))
    $protected = Get-Fingerprint (Get-ProtectedSnapshot $cliRoot $targetPaths)
    Move-Item -LiteralPath $targetPaths[0] -Destination (Join-Path $fixtureRoot 'quarantined-cache')
    Assert-True ((Get-Fingerprint (Get-ProtectedSnapshot $cliRoot $targetPaths)) -eq $protected) 'Moving cache must preserve non-target data.'

    Assert-WorkDirectory
    New-PrivateDirectory $stateRoot
    $acl = Get-Acl -LiteralPath $stateRoot
    Assert-True $acl.AreAccessRulesProtected 'Private directory must disable ACL inheritance.'
    Assert-True (@($acl.Access | Where-Object IsInherited).Count -eq 0) 'Private directory must have no inherited rules.'
    $stateRoot = Join-Path $cliRoot 'nested-state'
    Assert-Throws { Assert-WorkDirectory } 'outside'
    $stateRoot = $fixtureRoot
    Assert-Throws { Assert-WorkDirectory } 'cannot contain'
    $stateRoot = Join-Path $repositoryRoot 'state'
    Assert-Throws { Assert-WorkDirectory } 'outside'

    New-Item -ItemType Junction -Path $junctionPath -Target $copyRoot | Out-Null
    Assert-Throws { Get-Snapshot $junctionPath } 'Reparse point'
    $stateRoot = Join-Path $junctionPath 'state'
    Assert-Throws { Assert-WorkDirectory } 'reparse point'
    Remove-Item -LiteralPath $junctionPath -Force

    function Get-CimInstance {
        [pscustomobject]@{ Name='claude.exe'; ProcessId=123; CommandLine='fixture-only' }
    }
    Assert-Throws { Assert-Idle } 'running'
    function Get-CimInstance { }
    Assert-Idle

    # Exercise the script entrypoint in a child process with fixture-only roots.
    # Mock Windows path discovery and process discovery, never real Claude data.
    $source = [IO.File]::ReadAllText($scriptPath)
    $quoteProfile = "'" + $profileRoot.Replace("'", "''") + "'"
    $quoteRoaming = "'" + (Join-Path $profileRoot 'Roaming').Replace("'", "''") + "'"
    $source = $source.Replace("[Environment]::GetFolderPath('UserProfile')", $quoteProfile)
    $source = $source.Replace("[Environment]::GetFolderPath('ApplicationData')", $quoteRoaming)
    $source = $source.Replace('$ErrorActionPreference = ''Stop''', '$ErrorActionPreference = ''Stop''; function Get-CimInstance { }')
    $source = $source.Replace('$repositoryRoot = Split-Path -Parent $PSScriptRoot', '$repositoryRoot = Join-Path $PSScriptRoot ''repository-fixture''')
    $testScript = Join-Path $fixtureRoot 'entrypoint-fixture.ps1'
    [IO.File]::WriteAllText($testScript, $source)
    $childState = Join-Path $fixtureRoot 'child-state'
    $shellPath = (Get-Process -Id $PID).Path
    $savedConfigDir = [Environment]::GetEnvironmentVariable('CLAUDE_CONFIG_DIR')
    try {
        [Environment]::SetEnvironmentVariable('CLAUDE_CONFIG_DIR', $null)
        $output = & $shellPath -NoProfile -NonInteractive -File $testScript -Mode Audit -WorkDirectory $childState 2>&1
        Assert-True ($LASTEXITCODE -eq 0) "Fixture audit failed: $output"
        $plan = Get-Content -LiteralPath (Join-Path $childState 'plan.json') -Raw | ConvertFrom-Json
        Assert-True (@($plan.Targets).Count -eq 0) 'Audit must handle no targets.'
        $output = & $shellPath -NoProfile -NonInteractive -File $testScript -Mode Apply -WorkDirectory $childState 2>&1
        Assert-True ($LASTEXITCODE -eq 0) "No-target apply failed: $output"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $childState 'result.json'))) 'No-target apply must not create a batch or result.'

        New-Item -ItemType Directory -Path (Join-Path $cliRoot 'cache') | Out-Null
        [IO.File]::WriteAllText((Join-Path $cliRoot 'cache\sample.txt'), 'cached data')
        $output = & $shellPath -NoProfile -NonInteractive -File $testScript -Mode Audit -WorkDirectory $childState 2>&1
        Assert-True ($LASTEXITCODE -eq 0) "Populated audit failed: $output"
        $plan = Get-Content -LiteralPath (Join-Path $childState 'plan.json') -Raw | ConvertFrom-Json
        Assert-True (@($plan.Targets).Count -eq 1) 'Populated audit must discover the cache target.'
        $output = & $shellPath -NoProfile -NonInteractive -File $testScript -Mode Apply -WorkDirectory $childState 2>&1
        Assert-True ($LASTEXITCODE -ne 0) 'Apply must reject noninteractive confirmation.'
        Assert-True (($output | Out-String) -match 'interactive terminal') 'Apply must identify the confirmation blocker.'
        Assert-True (Test-Path -LiteralPath (Join-Path $cliRoot 'cache\sample.txt')) 'Rejected apply must preserve cache.'

        [IO.File]::WriteAllText((Join-Path $cliRoot 'cache\sample.txt'), 'modified!!!')
        $output = & $shellPath -NoProfile -NonInteractive -File $testScript -Mode Apply -WorkDirectory $childState 2>&1
        Assert-True ($LASTEXITCODE -ne 0) 'Apply must reject changes since audit.'
        Assert-True (($output | Out-String) -match 'changed since audit') 'Apply must identify stale data.'
    } finally {
        [Environment]::SetEnvironmentVariable('CLAUDE_CONFIG_DIR', $savedConfigDir)
    }
    Write-Output 'PASS: syntax, verified snapshots, empty targets, content changes, protected data, private ACLs, path boundaries, reparse points, running processes, audit entrypoint, no-op apply, noninteractive rejection and stale-plan rejection.'
} finally {
    if (Test-Path -LiteralPath $junctionPath) { Remove-Item -LiteralPath $junctionPath -Force }
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    $resolvedTests = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if (-not $resolvedFixture.StartsWith($resolvedTests, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing cleanup outside tests directory.' }
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
}
