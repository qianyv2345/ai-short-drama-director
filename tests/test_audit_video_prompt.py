"""Run the real PowerShell auditor. Python 3 + pwsh (or Windows powershell.exe)."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PWSH = os.environ.get('PWSH') or shutil.which('pwsh') or shutil.which('powershell.exe')
PREFIX = '整段视频默认无文字无字幕；剧本明确要求的剧情内文字除外。'
FIELDS = ['整体画面', '绝对主体与物理动势', '环境场与情绪光影', '摄影机调度', '时间轴与状态演变', '美学介质与底层渲染']


def fixture(ratio='9:16', seconds=15, detailed=False, metadata=False):
    head = (f'## 生成段编号\n\n17-S01\n\n## 包含分镜\n17-01至17-02\n\n## 总时长\n\n{seconds}秒\n\n## Prompt' if metadata else f'## 17-S01｜{seconds}秒')
    body = f'{head}\n画面比例：{ratio}\n{PREFIX}\n【场景】室内，无可读文字。\n【人物】\n@苏禾：坐在窗边。\n【镜头时间轴】\n'
    for start, end, shot in [(0, 5, '17-01'), (5, seconds, '17-02')]:
        action = '近景，@苏禾 坐在左侧，面朝右方，双手放在膝上，固定镜头。清晰人脸数量：1。'
        if detailed:
            body += f'**{start}-{end}秒｜{shot}**\n' + '\n'.join(f'{f}：{action if i == 0 else "固定状态。"}' for i, f in enumerate(FIELDS)) + '\n'
        else:
            body += f'{start}-{end}秒：{action}\n'
    return body + '【音效】室内环境声。\n【连续性限制】人物面容保持一致。\n'


@unittest.skipUnless(PWSH, 'Requires a real PowerShell runtime; set PWSH.')
class AuditorTests(unittest.TestCase):
    def audit(self, text, ratio='9:16', seconds=15, extra=(), source=None):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / 'prompt.md'
            p.write_text(text, encoding='utf-8')
            cmd = [PWSH, '-NoLogo', '-NoProfile', '-File', str(ROOT / 'scripts/audit_video_prompt.ps1'), '-PromptPath', str(p), '-MaxSegmentSeconds', str(seconds), '-AspectRatio', ratio, *extra]
            if source is not None:
                s = Path(td) / 'source.md'
                s.write_text(source, encoding='utf-8')
                cmd += ['-SourcePath', str(s)]
            result = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
            return result.returncode, result.stdout

    def assert_pass(self, text, **kw):
        code, output = self.audit(text, **kw)
        self.assertEqual(code, 0, output)
        self.assertIn('PASS warnings=', output)

    def assert_fail(self, text, reason, **kw):
        code, output = self.audit(text, **kw)
        self.assertNotEqual(code, 0, output)
        self.assertIn(reason, output)

    def test_explicit_identity_role_tag(self):
        text = fixture().replace('@苏禾', '@医生')
        self.assert_pass(text, extra=['-StrictCharacterReferences'])
        self.assert_fail(text.replace('近景，@医生', '近景，医生', 1), 'CHARACTER_TAG_MISSING', extra=['-StrictCharacterReferences'])

    def test_subject_binding_and_quote_exemption(self):
        text = fixture().replace('近景，@苏禾', '@苏禾面部特写，@苏禾')
        self.assert_pass(text + '\n', extra=['-StrictCharacterReferences'])
        self.assert_fail(text.replace('@苏禾面部特写', '面部特写', 1), 'SHOT_SUBJECT_UNBOUND', extra=['-StrictCharacterReferences'])
        text = text.replace('固定镜头。', '固定镜头，@苏禾「苏禾，走吧。」', 1)
        self.assert_pass(text, extra=['-StrictCharacterReferences'])

    def test_segment_same_subject_warns_not_fails(self):
        one = fixture().replace('近景，@苏禾', '@苏禾面部特写，@苏禾')
        code, output = self.audit(one + one.replace('17-S01', '17-S02'))
        self.assertEqual(code, 0, output)
        self.assertIn('SEGMENT_SEAM_SAME_SUBJECT', output)

    def test_continuous_dialogue_audio_span(self):
        text = fixture().replace('固定镜头。', '固定镜头。对白音轨：0-10秒。@苏禾「' + '长' * 40 + '」', 1)
        code, output = self.audit(text)
        self.assertEqual(code, 0, output)
        self.assertNotIn('Dialogue rate above', output)
        self.assert_fail(text.replace('对白音轨：0-10秒', '对白音轨：0-20秒'), 'DIALOGUE_AUDIO_SPAN_INVALID')

    def test_independent_matrix(self):
        for ratio in ('9:16', '16:9'):
            for seconds in (15, 30):
                for detailed in (False, True):
                    with self.subTest(ratio=ratio, seconds=seconds, detailed=detailed):
                        self.assert_pass(fixture(ratio, seconds, detailed), ratio=ratio, seconds=seconds)

    def test_bold_compact(self):
        text = fixture().replace('0-5秒：', '**0-5秒｜17-01**\n').replace('5-15秒：', '**5-15秒｜17-02**\n')
        self.assert_pass(text, extra=['-OutputFormat', 'Compact'])
        self.assert_fail(text.replace('固定镜头', '同上'), 'Relative continuity')
        self.assert_fail(text, 'OUTPUT_FORMAT', extra=['-OutputFormat', 'Detailed'])

    def test_metadata_legacy_template(self):
        self.assert_pass(fixture(metadata=True))

    def test_ratio_mismatch(self):
        self.assert_fail(fixture('16:9'), 'ASPECT_RATIO_MISMATCH')

    def test_legacy_without_ratio_warns(self):
        text = fixture().replace('画面比例：9:16\n', '')
        code, output = self.audit(text)
        self.assertEqual(code, 0, output)
        self.assertIn('ASPECT_RATIO_UNDECLARED', output)

    def test_portrait_clear_faces(self):
        self.assert_fail(fixture().replace('清晰人脸数量：1', '清晰人脸数量：2'), 'PORTRAIT_FACE_COUNT')

    def test_landscape_two_faces(self):
        self.assert_pass(fixture('16:9').replace('清晰人脸数量：1', '清晰人脸数量：2'), ratio='16:9')

    def test_portrait_wide_two_faces(self):
        self.assert_pass(fixture().replace('近景', '全景').replace('清晰人脸数量：1', '清晰人脸数量：2'))

    def test_format_explicit(self):
        self.assert_pass(fixture(), extra=['-OutputFormat', 'Compact'])
        self.assert_pass(fixture(detailed=True), extra=['-OutputFormat', 'Detailed'])
        self.assert_fail(fixture(), 'OUTPUT_FORMAT', extra=['-OutputFormat', 'Detailed'])
        self.assert_fail(fixture(detailed=True), 'OUTPUT_FORMAT', extra=['-OutputFormat', 'Compact'])

    def test_maximum(self):
        self.assert_fail(fixture(seconds=30), 'exceeds selected maximum')

    def test_gap_overlap(self):
        self.assert_fail(fixture().replace('5-15秒', '6-15秒'), 'gap or overlap')
        self.assert_fail(fixture().replace('5-15秒', '4-15秒'), 'gap or overlap')

    def test_time_granularity(self):
        self.assert_fail(fixture().replace('0-5秒', '0-5.2秒'), '0.5-second increments')

    def test_non_integer_segment(self):
        self.assert_fail(fixture().replace('｜15秒', '｜15.0秒'), 'written as an integer')

    def test_missing_prefix(self):
        self.assert_fail(fixture().replace(PREFIX, ''), 'No-subtitle prefix')

    def test_six_fields_per_shot(self):
        text = fixture(detailed=True)
        self.assert_fail(text.replace('整体画面：', '画面：', 1), 'Field count mismatch')
        # Keep total field counts unchanged but put both fields in one shot.
        text = text.replace('整体画面：', '画面：', 1).replace('整体画面：', '整体画面：固定状态。\n整体画面：', 1)
        self.assert_fail(text, 'Field count mismatch')

    def test_explicit_position_can_stay_fixed(self):
        self.assert_pass(fixture().replace('固定镜头。', '固定镜头，人物位置不变。'))

    def test_relative_continuity_compact(self):
        self.assert_fail(fixture().replace('固定镜头', '承接上一镜'), 'Relative continuity')

    def test_dialogue_match(self):
        self.assert_pass(fixture().replace('固定镜头。', '固定镜头，@苏禾「走吧。」', 1), source='苏禾：「走吧。」')
        self.assert_fail(fixture().replace('固定镜头。', '固定镜头，@苏禾「快走。」', 1), 'Dialogue mismatch', source='苏禾：「走吧。」')

    def test_entity_extra(self):
        self.assert_fail(fixture().replace('@苏禾', '@陆沉'), 'ENTITY_EXTRA', source='苏禾：坐着。', extra=['-StrictEntityAudit'])

    def test_absent_shot_detailed(self):
        self.assert_fail(fixture(detailed=True), 'Expected shot id is still present', extra=['-ExpectedAbsentShotId', '17-01'])

    def test_absent_shot_compact_requires_ids(self):
        self.assert_fail(fixture(), 'SHOT_ID_UNAVAILABLE', extra=['-ExpectedAbsentShotId', '17-01'])
        text = fixture().replace('0-5秒：', '0-5秒：镜头编号：17-01；').replace('5-15秒：', '5-15秒：镜头编号：17-02；')
        self.assert_fail(text, 'Expected shot id is still present', extra=['-ExpectedAbsentShotId', '17-01'])
        self.assert_pass(text, extra=['-ExpectedAbsentShotId', '17-99'])

    def test_duplicate_segment_id(self):
        self.assert_fail(fixture() + '\n' + fixture(), 'Duplicate segment id')

    def test_orphan_shot(self):
        self.assert_fail('**0-1秒｜00-01**\n' + fixture(detailed=True), 'ORPHAN_SHOT')

    def test_duplicate_shot_id(self):
        self.assert_fail(fixture(detailed=True).replace('17-02', '17-01'), 'Duplicate shot id')

    def test_no_timeline(self):
        self.assert_fail(fixture().replace('【镜头时间轴】', '【随便说明】'), 'No timed shot')

    def test_legacy_subtitle_prefix(self):
        self.assert_pass(fixture().replace(PREFIX, '整段视频无文字无字幕。'))

    def test_multi_segment(self):
        second = fixture().replace('17-S01', '17-S02')
        self.assert_pass(fixture() + '\n' + second)

if __name__ == '__main__':
    unittest.main(verbosity=2)
