# 资料维护工具

仓库根目录执行 `python learning/tools/catalog.py --write`，重新生成[全部资料导航](../资料导航.md)与机器可读清单，再检查所有课程README和本地Markdown目标是否存在。只检查时省略 `--write`。

报告写入 [资料检查.json](../归档/资料检查.json)，其中 `workspace_root` 标明检查的是哪个检出目录。这不是 GPU 测试，不重写课程完成状态、历史验收摘要，也不会删除文件。

发布仓库不包含运行生成的图片和 Nsight 报告。[精确生成物清单](generated-artifacts.json)记录了当前讲义引用的 42 个生成物及各自的课程 README。新电脑尚未恢复时，报告中的 `pending_generated` 将它们列为“待本地生成”；按条目的 `readme` 找到本课构建、运行或分析说明。已有文件计入 `known_generated_present`，不要求重新运行。清单不包含的坏链接仍会让检查失败，不能仅因文件在 `results/` 或以 `.png` 结尾就忽略。

`external_resources` 单独列出教材 PDF 和 Windows SDK 头文件这两处本机路径，显示是否存在；新电脑需自行准备教材或匹配已安装的 SDK 位置。它们不是随仓库发布的材料。`pass: true` 只表示课程 README 与仓内文档链接有效、缺失生成物均已明确声明，不表示图片已经恢复或实验重新通过。讲义中的原始图片链接在本地生成对应文件后即可显示。

[verify_organization.ps1](verify_organization.ps1) 是本轮 CUDA/粒子迁移回归工具，会重编译并执行 32 个案例。可从任意目录启动，日志写各课 `results/organization-check/`，[汇总](../sandbox/cuda/results/organization-check/summary.json)保存在 CUDA 线路的结果目录。它不执行 Nsight 硬件计数器分析。
