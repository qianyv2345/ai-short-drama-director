# AI 短剧导演技能

用于 Codex 的中文短剧制作技能：按需整理人物、场景与关键道具，设计指定集数或场次的影视分镜，并将确认后的分镜转换为 Seedance 等 AI 视频提示词。

## 能做什么

- 按剧本原文整理人物、场景和制作信息。
- 设计或局部修改镜头景别、机位、运镜、动作、表情和衔接。
- 输出15秒版或30秒版视频生成段，支持9:16竖屏与16:9横屏。
- 处理角色引用、长对白穿插、过肩关系、逐镜人物定位、道具与动作连续性。
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
references/workflow_rules.md        原有完整工作规则
references/storyboard_rules.md      分镜细则
references/seedance_rules.md         视频提示词细则
references/cinematic_prompt_rules.md 电影化详细格式
references/style_profiles.md        按需调用的风格档案
scripts/audit_video_prompt.ps1       文本审核脚本
```

## 提示词审核

在 Windows PowerShell 中运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\audit_video_prompt.ps1 -PromptPath 'D:\制作目录\提示词.md' -MaxSegmentSeconds 30 -AspectRatio '9:16'
```

`MaxSegmentSeconds` 为15或30；`AspectRatio` 为9:16或16:9，均必须显式提供。可追加 `-SourcePath`、`-Episode`、`-ExpectedEntity`、`-AllowedExtraEntity`、`-StrictEntityAudit`、`-ExpectedAbsentShotId` 等参数；具体用法见完整工作规则第23.1节。

审核通过仅代表脚本覆盖的文本检查通过。对白完整性、人物站位、镜头叙事和生成成片仍需人工复核。

## 本次整理

2026-11-03：将原有长入口拆分为精简技能入口与完整规则参考；保留原有四份参考文档和审核脚本，补充仓库安装与使用说明。原有已安装技能未被覆盖。