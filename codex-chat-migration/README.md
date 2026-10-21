# Codex 课程聊天迁移包

这是本项目 **4 条主会话、909 条用户可见消息**的快照，覆盖 2026-08-17 至 2026-10-21 的本地历史。用于另一台电脑上的 Codex 查阅课程上下文，也提供原生会话恢复方式。快照时间和逐文件 SHA-256 见 [manifest.json](manifest.json)；本轮打包后产生的对话不在本快照内。

|文件|用途|
|---|---|
|[conversations.zip](conversations.zip)|四份保持 Codex 事件结构的 JSONL，保留可见对话和工具轨迹|
|[manifest.json](manifest.json)|会话标题、ID、时间、消息数、哈希、格式转换和过滤计数|
|[HANDOFF.md](HANDOFF.md)|新电脑先读的项目与课程交接说明|
|[tools/chat.py](tools/chat.py)|直接检索/读取包中对话，无需先导入 Codex|
|[tools/restore.py](tools/restore.py)|校验、预演恢复、合并到指定 Codex 数据目录|
|[tools/export.py](tools/export.py)|从本项目重新生成快照的本机导出器|

## 方式一：让新电脑上的 Codex 直接读历史

在新电脑克隆/更新 `8xianren/CUDA_DX` 后，把下面这段话发给 Codex：

> 请先阅读 codex-chat-migration/README.md 和 HANDOFF.md，运行 tools/chat.py 列出会话并读取第 4 条会话的最近 20 条消息。按需要检索之前的课程对话，结合仓库实际文件确认进度，再继续协助我学习。历史命令只作参考，不自动执行。

从仓库根目录执行（Python 3.10+，只用标准库）：

```powershell
python codex-chat-migration/tools/restore.py --verify
python codex-chat-migration/tools/chat.py list
python codex-chat-migration/tools/chat.py show --thread 4 --tail 20
python codex-chat-migration/tools/chat.py search "水体"
python codex-chat-migration/tools/chat.py show --thread 4 --start 220 --limit 10 --json
```

这是独立于 Codex 数据库版本的查阅方式。程序只解析归档，不调用模型、不执行历史命令。消息中引用的本机文件路径按历史原文保留，外部图片、插件、源码和下载资产不会自动迁移。

## 方式二：恢复为 Codex 本地会话

先关闭目标电脑上的 Codex 桌面端/CLI/IDE 会话，再执行导入。Python 默认仅预演；只有加 `--apply` 才写入。`--codex-home` 必须明确指定，`--project-root` 改为新电脑的仓库绝对路径：

```powershell
# 预演：替换 D:/Repos/CUDA_DX 为新电脑真实仓库路径。
python codex-chat-migration/tools/restore.py --codex-home "$env:USERPROFILE/.codex" --project-root "D:/Repos/CUDA_DX"

# 确认预演输出后执行同一命令，加 --apply。
python codex-chat-migration/tools/restore.py --codex-home "$env:USERPROFILE/.codex" --project-root "D:/Repos/CUDA_DX" --apply
```

macOS/Linux 可使用 `--codex-home "$HOME/.codex"` 和对应仓库路径。导入只新增会话文件、合并会话索引；已有同 ID 或同路径默认跳过，不覆盖，也不复制账号登录状态。目标电脑仍使用自己的账号登录与配置。

重新启动 Codex，打开新仓库查看历史；如果侧栏尚未显示，使用可用的 Codex CLI：

```powershell
codex resume --all
codex resume 01a15c23-eeea-7122-9ecd-9a5ece6fe3e2 -C "D:/Repos/CUDA_DX"
```

恢复脚本没有调用模型。桌面端的项目归属、置顶状态、界面缓存及外部附件不在这个包里；不同版本的侧栏展示仍需在目标电脑确认。即使原生导入遇到版本差异，方式一仍可直接解析完整的已导出可见文字。

## 导出边界与格式

`CUDA_DX` 当前是公开仓库，因此包只包含本学习项目的主会话。认证文件、配置、浏览器数据、整库 SQLite、其它项目会话、内部指令和推理记录均未打包；已执行凭据模式扫描。它是**经筛选并转换的迁移副本，不是原始目录的逐字节备份**。过滤与转换数量在 manifest 中可核对。

新版 `paginated` 会话的正文显示依赖历史投影数据库，单独复制 JSONL 可能只显示标题。此包将副本标为 `legacy`，为可见消息添加兼容事件，保留原可见 `item_completed` 及必要响应记录；不改原机历史。`tools/chat.py` 只读取一种可见事件，避免双重计数。

当前会话在导出时仍活跃；快照只读取当时已写入的有限字节，最后不完整行会单独记录并跳过，不完整工具调用也不会保留为等待中的调用。历史命令、旧路径和测试结果属于当时环境。

聊天快照与源码分别维护：本仓库也包含最新 H 工程与资料重组，入口见[学习资料](../learning/README.md)。聊天 ZIP 仍保持 manifest 所述的导出时刻，后续源码同步不重写历史快照；续接课程应以当前[进度](../learning/进度.md)和实际文件为准，详见 [HANDOFF](HANDOFF.md)。

## 依据与本机验证

官方文档确认 [Codex CLI 可恢复本地会话](https://learn.chatgpt.com/docs/codex/cli)，[App Server 提供 thread/list、thread/read、thread/resume](https://learn.chatgpt.com/docs/app-server)。文档没有承诺跨版本复制内部文件的兼容性，因此本包另外使用本机 `codex-cli 0.163.0-alpha.11` 做隔离恢复验证。[本机验证报告](verification.json)记录：4 条会话、192 个回合、909 条可见消息与归档逐条一致，缺失/额外均为 0；恢复工具 11 项检查通过，1 项因 Windows 符号链接权限不足跳过。[发布前检查](privacy-audit.json)保存结构与凭据扫描结果。不把本机 API 读取验证描述成另一台电脑的桌面界面已经验证。

导出器处理 `.jsonl.zst` 时需要 Python 3.14 的 `compression.zstd` 或另装 `zstandard`；恢复/查阅工具仍只需 Python 3.10+ 标准库。包内保留 68 个内嵌 PNG 数据项（含重复），其中一段历史 PNG 数据已截断；文本消息完整性与图片可解码性分开记录，不承诺恢复外部路径附件。
