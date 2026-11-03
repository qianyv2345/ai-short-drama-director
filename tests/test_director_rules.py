"""Static routing/contradiction regressions, not an artistic quality rating."""
from pathlib import Path
import re
import unittest
ROOT = Path(__file__).resolve().parents[1]
class DirectorRules(unittest.TestCase):
    def test_local_markdown_links_resolve(self):
        for p in ROOT.rglob('*.md'):
            if '.git' in p.parts: continue
            for target in re.findall(r'\]\(([^)]+)\)', p.read_text(encoding='utf-8-sig')):
                if '://' in target or target.startswith('#'): continue
                self.assertTrue((p.parent / target.split('#')[0]).exists(), (p, target))
    def test_no_legacy_mechanical_editing_rules(self):
        banned=['必须先切回','至少出现一种补充画面','禁止同一人物脸部出现','尽快回到近景体系','可根据剧情增加镜头和运镜','时间刻度仅作参考','Seedance必须基于确定后的分镜']
        for p in [ROOT/'SKILL.md', *(ROOT/'references').glob('*.md')]:
            text=p.read_text(encoding='utf-8-sig')
            for phrase in banned: self.assertNotIn(phrase,text,str(p))
    def test_entry_routes_shared_and_aspect_rules(self):
        text=(ROOT/'SKILL.md').read_text()
        for path in ['references/director_core.md','references/aspect_ratio_profiles.md']:
            self.assertIn(path,text)
    def test_core_preserves_boundaries(self):
        text=(ROOT/'references/director_core.md').read_text()
        for token in ['原对白','不自动加3秒钩子','15 / 30秒','0.5秒','S02末帧','超过5秒','六字段']:
            self.assertIn(token,text)
    def test_profiles_have_both_dimensions(self):
        text=(ROOT/'references/aspect_ratio_profiles.md').read_text()
        for token in ['## 9:16','## 16:9','不继承竖屏单脸约束','单脸','15/30秒','两画幅 × 两时长 × 两输出格式']:
            self.assertIn(token,text)
if __name__=='__main__': unittest.main()
