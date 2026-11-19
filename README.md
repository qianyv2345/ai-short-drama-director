# AI 短剧导演技能 V4

用于 Codex 的中文短剧制作技能。按指定集数或场次整理人物与场景、设计或修改分镜，并把确认后的分镜转换为 Seedance 等 AI 视频提示词。

## 安装

在 Windows PowerShell 运行：

```powershell
$codexSkillRoot = if ($env:CODEX_HOME) { Join-Path $env:CODEX_HOME 'skills' } else { Join-Path $env:USERPROFILE '.codex\skills' }
git clone https://github.com/qianyv2345/ai-short-drama-director.git (Join-Path $codexSkillRoot 'ai-short-drama-director')
```

已有同名技能时先备份。安装后在 Codex 中调用 `$ai-short-drama-director`。

## V4 提示词

- 支持 15 秒版和 30 秒版，以及 9:16 竖屏和 16:9 横屏。同一项目沿用用户已确认的参数。
- 默认逐镜写画面、运镜、光影、台词、音效，也支持电影化六字段。
- 共用规则涵盖原台词、`@` 人物指向、过肩机位、竖屏单脸、跨段动作和景别衔接。
- 首帧和场景生图提示词按需提供。生成、配音、剪辑和成片验收由对应工具完成。

查看 [技能入口](SKILL.md)、[9:16 五行样稿](examples/seedance_five_line_9x16.md) 和 [16:9 六字段样稿](examples/cinematic_6field_16x9.md)。

## 提示词质检

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\audit_video_prompt.ps1 -PromptPath .\examples\seedance_five_line_9x16.md -MaxSegmentSeconds 15 -AspectRatio '9:16'
```

使用 `-ExpectedDialoguePath` 提供指定范围的原台词清单，可检查原文、说话人和 OS 等声音类型。清单格式和其他参数见 [SKILL.md](SKILL.md)。测试方法见 [tests/README.md](tests/README.md)。

## 许可证

[MIT](LICENSE)
