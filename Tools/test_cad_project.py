import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from cad_project import install_skill

BUNDLE = Path(__file__).resolve().parents[1] / 'Resources/cad-skill.json'

class CADProjectTests(unittest.TestCase):
    def test_shipped_skill_installs_all_references_and_can_be_reused(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)/'cad'
            receipt = install_skill(BUNDLE, root)
            self.assertEqual(receipt['version'], '0.6.6')
            self.assertTrue((root/'SKILL.md').read_text().startswith('---'))
            before = (root/'references/step-generation.md').stat().st_mtime_ns
            self.assertEqual(install_skill(BUNDLE, root), receipt)
            self.assertEqual((root/'references/step-generation.md').stat().st_mtime_ns, before)
            self.assertIn('warm daemon', (root/'references/step-generation.md').read_text())
            self.assertTrue((root/'LICENSE').is_file())

    def test_bad_paths_and_symlink_escape_do_not_write_outside_the_skill(self):
        with TemporaryDirectory() as directory:
            root = Path(directory); target = root/'cad'; target.mkdir()
            outside = root/'outside'; outside.mkdir(); (target/'link').symlink_to(outside, target_is_directory=True)
            for path in ['../escaped', '/escaped', 'references/../../escaped', 'bad\\path', 'link/escaped']:
                package = json.loads(BUNDLE.read_text())
                package['files'] = [{'path': path, 'content': 'bad'}]
                bundle = root/'input.json'; bundle.write_text(json.dumps(package))
                with self.assertRaises(ValueError): install_skill(bundle, target)
            self.assertEqual(list(outside.iterdir()), [])
            self.assertFalse((root/'escaped').exists())

    def test_wrong_skill_revision_is_rejected_before_files_are_installed(self):
        with TemporaryDirectory() as directory:
            root=Path(directory); package=json.loads(BUNDLE.read_text()); package['revision']='unknown'
            bundle=root/'input.json'; bundle.write_text(json.dumps(package))
            with self.assertRaises(ValueError): install_skill(bundle, root/'cad')
            self.assertFalse((root/'cad').exists())

if __name__ == '__main__': unittest.main(verbosity=2)
