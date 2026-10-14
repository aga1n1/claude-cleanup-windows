---
name: claude-cleanup-windows
description: 在 Windows 上审计并清理 Claude Code 和 Claude Desktop 的可再生缓存与日志，先完整备份再移入私有隔离目录，保留会话、配置、插件、身份和登录态。用于本机维护与排障，不用于 macOS、卸载、身份轮换或规避平台风控。
---

# Claude Windows 缓存清理

使用随附 `scripts/claude-cleanup-windows.ps1`，需要 Windows 和 PowerShell 7.2 以上。仅支持默认的 `%USERPROFILE%\.claude` 与 `%APPDATA%\Claude`；遇到自定义 `CLAUDE_CONFIG_DIR`、目录链接或读取失败时停止，不临时扩大清理范围。

## 执行流程

1. 如果执行者是正在使用目标目录的 Claude Code，只做 Audit，不自行修改其状态。清理应由 Codex 或用户终端执行。
2. 运行审计。默认工作目录为系统 API 返回的 LocalApplicationData 下的 `ClaudeCleanup`；可用 `-WorkDirectory` 指定仓库和 Claude 数据之外的新目录。

   ```powershell
   pwsh -NoProfile -File ".\scripts\claude-cleanup-windows.ps1" -Mode Audit
   ```

3. 向用户展示展开后的路径、文件数量和大小；解释完整备份、隔离目录位置及不立即释放磁盘空间。审计会记录正在运行的 Claude 进程；如有进程，用户正常退出后重新 Audit，不自动结束进程。
4. 用户同意继续后，在真实交互终端运行 Apply，使用与 Audit 相同的 WorkDirectory：

   ```powershell
   pwsh -NoProfile -File ".\scripts\claude-cleanup-windows.ps1" -Mode Apply
   ```

   由用户本人输入一次 `CONFIRM`。不要管道代答、模拟键盘输入、增加跳过确认参数或修改脚本绕过确认。如果执行环境不支持用户交互终端，交给用户执行这一步。
5. 报告 `result.json` 的实际状态、备份及隔离路径、移动项数量。`Partial` 或非零退出码表示未完整完成，不声称成功。没有目标时返回无操作结果，不创建备份批次。

## 固定范围

只移动存在的以下路径：

- `%USERPROFILE%\.claude\` 下的 `cache`、`stats-cache.json`、`telemetry`、`usage-data`、`usage.jsonl`、`usage.with-fix.jsonl`。
- `%APPDATA%\Claude\` 下的 `Cache`、`Code Cache`、`GPUCache`、`DawnGraphiteCache`、`DawnWebGPUCache`、`logs`。
- `%USERPROFILE%\AppData\Local\claude-cli-nodejs`。

白名单外所有内容保持不变，包括 sessions、projects、history、skills、plugins、hooks、MCP、settings、`.claude.json`、Desktop 持久存储、身份及登录态。不得扩大为整个 Claude 目录，也不重置身份、卸载应用、改变遥测设置、精简模式或时区。

## 校验与恢复

Apply 在修改 Claude 数据前完整复制 `.claude` 和存在的 `.claude.json`，校验文件路径、空目录、大小和 SHA-256；然后按白名单移动缓存和日志，逐项验证隔离副本及未清理的数据。源数据在审计后变化时停止，重新审计并重新展示清单。

工作目录使用私有 Windows ACL。备份包含个人配置和历史，不能提交、上传或用于发布示例。恢复时先关闭 Claude，按 `result.json` 中的 Source/Destination 映射逐项核对；若原位置已有新缓存，不强制覆盖，先说明冲突并由用户选择处理方式。不得自动清空隔离目录。

源流程：[Suyuan claude-cleanup](https://github.com/suyuan2022/suyuan-skill/tree/main/claude-cleanup)，MIT 许可。本版实现限定为 Windows 缓存及日志维护。
