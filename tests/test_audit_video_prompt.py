"""Run the actual V4 PowerShell auditor against the public examples."""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PWSH = os.environ.get("PWSH") or shutil.which("pwsh") or shutil.which("powershell")
AUDITOR = ROOT / "scripts" / "audit_video_prompt.ps1"
VERTICAL = ROOT / "examples" / "seedance_five_line_9x16.md"
HORIZONTAL = ROOT / "examples" / "cinematic_6field_16x9.md"


@unittest.skipUnless(PWSH, "Requires PowerShell. Set PWSH to its path.")
class AuditorTests(unittest.TestCase):
    def audit(self, text, seconds=15, aspect="9:16", dialogue=None):
        with tempfile.TemporaryDirectory() as directory:
            prompt = Path(directory) / "prompt.md"
            prompt.write_text(text, encoding="utf-8")
            command = [PWSH, "-NoProfile", "-ExecutionPolicy", "Bypass",
                       "-File", str(AUDITOR), "-PromptPath", str(prompt),
                       "-MaxSegmentSeconds", str(seconds), "-AspectRatio", aspect]
            if dialogue is not None:
                expected = Path(directory) / "dialogue.json"
                expected.write_text(json.dumps(dialogue, ensure_ascii=False), encoding="utf-8")
                command.extend(["-ExpectedDialoguePath", str(expected)])
            result = subprocess.run(command, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=30)
            return result.returncode, result.stdout.decode("utf-8", errors="replace")

    def test_examples(self):
        for path, seconds, aspect, kind in (
            (VERTICAL, 15, "9:16", "FIVE_LINE"),
            (HORIZONTAL, 30, "16:9", "CINEMATIC_6"),
        ):
            with self.subTest(example=path.name):
                code, output = self.audit(path.read_text(encoding="utf-8"), seconds, aspect)
                self.assertEqual(code, 0, output)
                self.assertIn(f"FORMAT={kind}", output)

    def test_invalid_camera_times(self):
        original = VERTICAL.read_text(encoding="utf-8")
        for start, expected in (("0", "must stay within shot"), ("4.1", "0.5-second increments")):
            with self.subTest(start=start):
                code, output = self.audit(original.replace("运镜：4-7秒：", f"运镜：{start}-7秒："))
                self.assertEqual(code, 1, output)
                self.assertIn(expected, output)

    def test_dialogue_speaker_type_and_completeness(self):
        example = VERTICAL.read_text(encoding="utf-8")
        prompt = "## 17-S01A" + example.split("## 17-S01A", 1)[1]
        line = '台词：@沈舟（0.5秒起，低声）「你还没走？」'
        self.assertIn(line, prompt)
        expected = {"dialogue_free": False, "utterances": [
            {"role": "沈舟", "kind": "对白", "text": "你还没走？"}
        ]}
        code, output = self.audit(prompt, dialogue=expected)
        self.assertEqual(code, 0, output)
        for replacement, reason in (
            (line.replace("@沈舟", "@阿宁"), "speaker or kind mismatch"),
            (line.replace("（0.5秒起，低声）", "（OS）"), "speaker or kind mismatch"),
            ("台词：无。", "missing or incomplete"),
        ):
            with self.subTest(replacement=replacement):
                code, output = self.audit(prompt.replace(line, replacement), dialogue=expected)
                self.assertEqual(code, 1, output)
                self.assertIn(reason, output)
