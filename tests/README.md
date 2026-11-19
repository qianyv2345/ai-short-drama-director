# V4 文本质检回归测试

需要 Python 3 和 PowerShell。可用环境变量 `PWSH` 指定 PowerShell 路径。

```powershell
python -m unittest discover -s tests -v
```

覆盖公开样稿、镜内切镜时间、台词归属与完整性，以及技能入口引用。测试使用合成文字样稿。
