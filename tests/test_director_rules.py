"""Check that the published V4 skill includes its routed references."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class DirectorRulesTests(unittest.TestCase):
    def test_entry_references_exist(self):
        entry = (ROOT / "SKILL.md").read_text(encoding="utf-8")
        route_paths = re.findall(r"`((?:references|scripts)/[^<>`]+\.(?:md|ps1))`", entry)
        self.assertIn("references/shared_constraints.md", route_paths)
        for path in set(route_paths):
            with self.subTest(path=path):
                self.assertTrue((ROOT / path).is_file())
