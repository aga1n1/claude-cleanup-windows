# Claude Cleanup for Windows

用于 Codex 的 Windows skill：审计 Claude Code / Claude Desktop 的可再生缓存与日志，先完整备份，再移入可恢复的私有隔离目录。

## 行为

- 固定路径白名单，保留会话、项目、配置、skills、plugins、MCP、身份和登录态。
- 清理前完整备份 `.claude` 与存在的 `.claude.json`，用 SHA-256 校验。
- 检查 Claude 相关进程与目录链接；出现变化或错误时停止。
- 用户在真实终端输入 `CONFIRM` 后执行，不提供跳过确认参数。
- 不永久删除文件、不自动结束进程，也不改变时区或遥测配置。

## 安装为 Codex skill

将整个仓库目录复制为 `$env:USERPROFILE\.codex\skills\claude-cleanup-windows`。然后在 Codex 中请求：

```text
使用 $claude-cleanup-windows 审计我的 Claude 缓存，并展示清理清单。
```

Windows + PowerShell 7.2 以上；建议由 Codex 或独立用户终端执行，不让 Claude Code 清理自身正在使用的数据。

## 直接运行

在仓库根目录执行：

```powershell
# 审计源数据，仅将清单写入私有工作目录
pwsh -NoProfile -File ".\scripts\claude-cleanup-windows.ps1" -Mode Audit

# 展示最终清单；用户本人输入 CONFIRM 后才开始备份和移动
pwsh -NoProfile -File ".\scripts\claude-cleanup-windows.ps1" -Mode Apply
```

默认工作目录为 Windows 系统 API 返回的 `LocalApplicationData\ClaudeCleanup`。它存放 `plan.json`、`result.json` 和时间戳备份/隔离批次。可通过 `-WorkDirectory "D:\ClaudeCleanup"` 指定新目录；两个命令必须使用同一目录。不能把工作目录放在仓库或 Claude 数据目录中。

本版只支持默认 Claude 路径。`CLAUDE_CONFIG_DIR` 非空时拒绝操作。源文件自审计后变化时，重新 Audit 并重新审阅清单。

## 恢复与限制

移动到隔离目录不会立即释放磁盘空间，完整备份还会额外占用空间。后续使用 Claude 时缓存可能重建。

恢复前关闭 Claude，按 `result.json` 的 `Moves` 对照原路径与隔离路径。不要直接覆盖后来生成的文件；有冲突时先保留两份再决定处理方式。备份可能包含个人配置和历史，应保持私有，不能提交到 Git。

这里只处理本机缓存与日志，不重置身份或登录，不用于规避封禁或平台风控。

## 验证

```powershell
pwsh -NoProfile -File ".\tests\smoke.ps1"
```

测试使用独立临时样本目录，不清理真实 Claude 数据。源版本曾在 Windows + PowerShell 7.6.5 下完成实际备份、10 项缓存/日志移动及受保护数据校验；可复用发布版的验证结果应以测试输出为准。

## 来源与许可

Windows 适配流程参考 [suyuan2022/suyuan-skill 的 claude-cleanup](https://github.com/suyuan2022/suyuan-skill/tree/main/claude-cleanup)。保留上游 MIT 版权与许可，见 [LICENSE](LICENSE)。
