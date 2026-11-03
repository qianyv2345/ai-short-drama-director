# AI 短剧导演技能

用于 Codex 的中文短剧制作技能：按需整理人物、场景与关键道具，设计指定集数或场次的影视分镜，并将确认后的分镜转换为 Seedance 等 AI 视频提示词。

## 能做什么

- 按剧本原文整理人物、场景和制作信息。
- 设计或局部修改镜头景别、机位、运镜、动作、表情和衔接。
- 输出15秒版或30秒版视频生成段，支持9:16竖屏与16:9横屏。
- 处理角色引用、有动机的切镜与停留、过肩关系、人物定位、道具与动作连续性。
- 根据明确要求生成首帧或图片提示词，调用已选择的视觉风格。
- 使用 PowerShell 脚本检查视频提示词文本。

技能只在明确要求的制作阶段和范围内工作。它不自带视频生成服务、API 密钥、角色图片或剧本素材。

## 安装

将本仓库下载或克隆为 Codex 技能目录中的 `ai-short-drama-director` 文件夹，确保 `SKILL.md` 直接位于该文件夹内。

Windows PowerShell（默认 Codex 配置位置；已设置 CODEX_HOME 时使用该目录）：

```powershell
$codexSkillRoot = if ($env:CODEX_HOME) { Join-Path $env:CODEX_HOME 'skills' } else { Join-Path $env:USERPROFILE '.codex\skills' }
git clone https://github.com/qianyv2345/ai-short-drama-director.git (Join-Path $codexSkillRoot 'ai-short-drama-director')
```

私有仓库需先具备 GitHub 访问权限。目标目录已存在时，先备份已有版本，避免覆盖。安装后在 Codex 的技能列表检查是否已发现；必要时重新打开应用。

## 使用示例

```text
使用 $ai-short-drama-director 读取这个剧本，先别输出。
整理第7—10集场景。
制作第17集第二场分镜。
把17-04改成固定镜头，另存一版。
把第17集镜头5—8转成30秒版、9:16竖屏的Seedance提示词。
只提取17-1中的某个镜头，补成可独立使用的子提示词。
```

视频提示词请求缺少时长或画面比例时，技能会先询问。未在当前任务调用的视觉风格不会自动加入。

## 文件结构

```text
SKILL.md                             技能入口与任务路由
references/director_core.md         共享导演决策、节拍、动作预算与修改传播
references/aspect_ratio_profiles.md  独立横屏/竖屏构图策略
references/workflow_rules.md        制作流程与资产规则
references/storyboard_rules.md      分镜细则
references/seedance_rules.md         视频提示词细则
references/cinematic_prompt_rules.md 电影化详细格式
references/style_profiles.md        按需调用的风格档案
scripts/audit_video_prompt.ps1       简版/六字段文本审核脚本
examples/directing_examples.md      导演决策对照示例
tests/                             审核器与规则回归测试
```

## 提示词审核

在 Windows PowerShell 中运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\audit_video_prompt.ps1 -PromptPath 'D:\制作目录\提示词.md' -MaxSegmentSeconds 30 -AspectRatio '9:16'
```

`OutputFormat` 可设为 `Compact`（默认简版）、`Detailed`（六字段）或 `Auto`（默认自动识别，兼容已有文件）；未识别格式仍会失败，不会静默跳过检查。`MaxSegmentSeconds` 为15或30；`AspectRatio` 为9:16或16:9，均必须显式提供。可追加 `-SourcePath`、`-Episode`、`-ExpectedEntity`、`-AllowedExtraEntity`、`-StrictEntityAudit`、`-ExpectedAbsentShotId` 等参数；具体用法见完整工作规则第23.1节。

审核通过仅代表脚本覆盖的文本检查通过。对白完整性、人物站位、镜头叙事和生成成片仍需人工复核。

## 本次整理

2026-11-03：将原有长入口拆分为精简技能入口与完整规则参考；保留原有四份参考文档和审核脚本，补充仓库安装与使用说明。原有已安装技能未被覆盖。

## 导演质量升级（2026-11-03）

共同导演核心负责剧情、表演、节拍和动作可执行性；画幅配置分别处理9:16单脸稳定性与16:9多人空间调度。画幅、15/30秒上限、简版/六字段、真人/CG四个维度独立。超过5秒不再强制插镜；同主体镜头先按叙事功能判断，不为去重硬插空镜或回切。每次局部修改回查前后生成段状态。

六字段格式保留，但减少字段间重复；简版不会被审核器强制补成六字段。CG内置前缀改为遵守确定时间轴，不再授权临场加镜；用户明确提供的固定原文若冲突仍先确认。保留不改台词、逐集制作、无默认3秒钩子和按需资产整理等边界。

仓库更新不等于已安装技能更新。安装目录已有文件时先核对其来源/版本并备份，不自动覆盖其他本地修改。运行环境和测试结果见下方验证记录。

直接提供剧本和请求即可生成提示词，不需要先生成或批准一份分镜；导演规划在内部完成。每镜最低时长、语速上限、手环位置等按当前请求传递，不设成全局硬编码。

## 验证记录

- Python 3 + PowerShell 7.4.6（Linux）执行32项回归测试通过，包含两画幅 × 两时长 × 两格式8组合及兼容/负例。
- 5份既有提示词完成文本审核；保留口播估算与画幅声明警告。附件与用户剧本未加入仓库。
- 技能 frontmatter 校验和 `git diff --check` 通过。
- 尚未实测 Windows PowerShell 5.1，尚未生成或验收视频。脚本通过不能证明动作自然、左右手正确或达到某种导演水平。

```powershell
python -m unittest discover -s tests -p 'test*.py' -v
```

需 Python 3 与可用 PowerShell；完整说明见 [测试说明](tests/README.md)。

## AI短剧执行改进（角色、接镜与运镜）

新增 [AI视频执行规则](references/ai_video_execution.md)：具体身份角色如医生也使用@标签；人物景别直接绑定主体；长对白优先有意义的反应/相关画面，声音连续；独立生成段不默认同脸同机位无缝延续。主动按剧情选择轻推、侧移、跟拍或微手持，不等待每次追加运镜要求，也不强迫所有镜头动。

审核参数 `-StrictCharacterReferences` 可用于新稿；默认对旧稿保持警告兼容。检查只针对可解析的显式角色/镜头，不是人脸或视频语义识别。跨段同主体提示需要人工判断景别、状态与轴线，不意味着绝对禁止同人接镜。
