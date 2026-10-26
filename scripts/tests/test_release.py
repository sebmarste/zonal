import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('release', Path(__file__).parents[1] / 'release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name)
        self.data = dict(schemaVersion=1, tag='v1.2.3', version='1.2.3', build='1',
                         commit='a' * 40, team='ABCDEFGHIJ', artifacts={})
        for name in ['Zonal-1.2.3.dmg', 'Zonal-1.2.3-evidence.zip', 'release-notes.md']:
            (self.output / name).write_text(name)
            self.data['artifacts'][name] = release.digest(self.output / name)
        (self.output / 'manifest.json').write_text(json.dumps(self.data))
        (self.output / 'SHA256SUMS').write_text(''.join(
            f'{release.digest(self.output / name)}  {name}\n'
            for name in [*self.data['artifacts'], 'manifest.json']))

    def test_retained_candidate_passes_but_changed_asset_or_manifest_fails(self):
        self.assertEqual(release.verify(self.output, 'v1.2.3'), self.data)
        notes = self.output / 'release-notes.md'
        notes.write_text('modified')
        with self.assertRaisesRegex(ValueError, 'Artifact mismatch'):
            release.verify(self.output, 'v1.2.3')
        notes.write_text('release-notes.md')
        (self.output / 'manifest.json').write_text(json.dumps(self.data) + ' ')
        with self.assertRaisesRegex(ValueError, 'Checksum file mismatch'):
            release.verify(self.output, 'v1.2.3')

    def test_rejects_missing_evidence_path_traversal_and_wrong_tag(self):
        for name in ['../secret', '/tmp/secret', 'Zonal-1.2.3.dmg']:
            data = copy.deepcopy(self.data)
            data['artifacts'] = {name: '0' * 64}
            with self.assertRaises(ValueError):
                release.validate_manifest(data, 'v1.2.3')
        with self.assertRaises(ValueError):
            release.validate_manifest(self.data, 'v1.2.4')
        for tag in ['--help', 'v1;echo bad', '../v1.2.3']:
            with self.assertRaises(ValueError):
                release.validate_tag(tag)

    def test_disk_image_always_detaches_even_when_payload_is_invalid(self):
        calls = []
        def run(*args, **kwargs):
            calls.append(args)
            if args[:2] == ('hdiutil', 'attach'):
                mount = Path(args[args.index('-mountpoint') + 1])
                mount.mkdir()
                (mount / 'Zonal.app').mkdir()
                (mount / 'Applications').symlink_to('/tmp/wrong-target')
        with patch.object(release, 'run', side_effect=run):
            with self.assertRaisesRegex(ValueError, 'link to /Applications'):
                with release.mounted_dmg(self.output / 'candidate.dmg'):
                    self.fail('Invalid image accepted')
        self.assertEqual(calls[-1][:2], ('hdiutil', 'detach'))

    def test_disk_image_detaches_after_assessment_failure(self):
        calls = []
        def run(*args, **kwargs):
            calls.append(args)
            if args[:2] == ('hdiutil', 'attach'):
                mount = Path(args[args.index('-mountpoint') + 1])
                mount.mkdir()
                (mount / 'Zonal.app').mkdir()
                (mount / 'Applications').symlink_to('/Applications')
        with patch.object(release, 'run', side_effect=run):
            with self.assertRaisesRegex(ValueError, 'assessment failed'):
                with release.mounted_dmg(self.output / 'candidate.dmg'):
                    raise ValueError('assessment failed')
        self.assertEqual(calls[-1][:2], ('hdiutil', 'detach'))

    def test_upload_rejects_other_source_commit_before_network_mutation(self):
        with patch.object(release, 'verify', return_value=self.data), \
             patch.object(release, 'source_commit', return_value='b' * 40), \
             patch.object(release, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'another source'):
                release.upload(self.output, 'v1.2.3')
            run.assert_not_called()

    def test_release_build_rejects_development_signing_before_build(self):
        with patch.object(release, 'version_info', return_value=('1.2.3', '1')), \
             patch.object(release, 'source_commit', return_value='a' * 40), \
             patch.object(release, 'run', return_value=''), \
             patch.dict(release.os.environ, {'ZONAL_SIGN_IDENTITY': 'Apple Development: example',
                                            'ZONAL_TEAM_ID': 'ABCDEFGHIJ'}):
            with self.assertRaisesRegex(ValueError, 'Developer ID'):
                release.build(self.output / 'new', 'v1.2.3', self.output / 'release-notes.md')
            self.assertFalse((self.output / 'new').exists())

    def test_upload_retry_preserves_equal_assets_and_fills_only_missing_assets(self):
        calls = []
        def run(*args, **kwargs):
            calls.append(args)
            if args[:2] == ('git', 'ls-remote'):
                return 'a' * 40 + '\trefs/tags/v1.2.3^{}\n'
            if args[:3] == ('gh', 'release', 'view'):
                return json.dumps({'isDraft': True, 'body': 'release-notes.md', 'assets': [{'name': 'Zonal-1.2.3.dmg'}]})
            if args[:3] == ('gh', 'release', 'download'):
                (Path(args[-1]) / 'Zonal-1.2.3.dmg').write_bytes((self.output / 'Zonal-1.2.3.dmg').read_bytes())
        with patch.object(release, 'verify', return_value=self.data), \
             patch.object(release, 'source_commit', return_value='a' * 40), \
             patch.object(release.subprocess, 'run') as process, patch.object(release, 'run', side_effect=run):
            process.return_value.returncode = 0
            release.upload(self.output, 'v1.2.3')
        uploads = [Path(call[-1]).name for call in calls if call[:3] == ('gh', 'release', 'upload')]
        self.assertEqual(uploads, ['Zonal-1.2.3-evidence.zip', 'release-notes.md', 'manifest.json', 'SHA256SUMS'])
        self.assertFalse(any('--clobber' in call or '--draft=false' in call for call in calls))

    def test_draft_notes_require_unpublished_nonempty_body(self):
        for draft in [{'isDraft': False, 'body': 'Notes'},
                      {'isDraft': True, 'body': '  '},
                      {'isDraft': True, 'body': None}]:
            with self.subTest(draft=draft), patch.object(release, 'run', return_value=json.dumps(draft)):
                with self.assertRaises(ValueError):
                    release.draft_notes('v1.2.3')
        with patch.object(release, 'run', return_value=json.dumps({'isDraft': True, 'body': 'Reviewed notes'})):
            self.assertEqual(release.draft_notes('v1.2.3'), 'Reviewed notes\n')

    def test_upload_rejects_changed_draft_notes_before_asset_upload(self):
        def run(*args, **kwargs):
            if args[:2] == ('git', 'ls-remote'):
                return 'a' * 40 + '\trefs/tags/v1.2.3\n'
            if args[:3] == ('gh', 'release', 'view'):
                return json.dumps({'isDraft': True, 'body': 'Changed after build', 'assets': []})
            self.fail(f'Unexpected mutation: {args}')
        with patch.object(release, 'verify', return_value=self.data), \
             patch.object(release, 'source_commit', return_value='a' * 40), \
             patch.object(release.subprocess, 'run') as process, patch.object(release, 'run', side_effect=run):
            process.return_value.returncode = 0
            with self.assertRaisesRegex(ValueError, 'Draft notes differ'):
                release.upload(self.output, 'v1.2.3')

    def test_upload_does_not_replace_existing_different_bytes(self):
        calls = []
        def run(*args, **kwargs):
            calls.append(args)
            if args[:2] == ('git', 'ls-remote'):
                return 'a' * 40 + '\trefs/tags/v1.2.3\n'
            if args[:3] == ('gh', 'release', 'view'):
                return json.dumps({'isDraft': True, 'body': 'release-notes.md', 'assets': [{'name': 'Zonal-1.2.3.dmg'}]})
            if args[:3] == ('gh', 'release', 'download'):
                (Path(args[-1]) / 'Zonal-1.2.3.dmg').write_text('different bytes')
        with patch.object(release, 'verify', return_value=self.data), \
             patch.object(release, 'source_commit', return_value='a' * 40), \
             patch.object(release.subprocess, 'run') as process, patch.object(release, 'run', side_effect=run):
            process.return_value.returncode = 0
            with self.assertRaisesRegex(ValueError, 'Existing asset differs'):
                release.upload(self.output, 'v1.2.3')
        self.assertFalse(any(call[:3] == ('gh', 'release', 'upload') for call in calls))


if __name__ == '__main__':
    unittest.main()
