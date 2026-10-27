import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    'prepare_release', Path(__file__).parents[2] / '.github/scripts/prepare-release.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class PrepareReleaseTests(unittest.TestCase):
    def test_only_increasing_app_version_and_build_create_a_release(self):
        self.assertIsNone(prepare.bumped_tag(('0.5.2', '74'), ('0.5.2', '75')))
        self.assertEqual(prepare.bumped_tag(('0.5.9', '74'), ('0.5.10', '75')), 'v0.5.10')
        for current in [('0.5.1', '75'), ('0.5.3', '74'), ('0.5.3', 'invalid'), ('0.5.3-beta', '75')]:
            with self.subTest(current=current), self.assertRaises(ValueError):
                prepare.bumped_tag(('0.5.2', '74'), current)

    def test_published_or_retained_candidates_cannot_be_rebuilt(self):
        for draft, retained in [
            ({'isDraft': False, 'body': 'Notes'}, set()),
            ({'isDraft': True, 'body': 'Notes', 'assets': [{'name': 'app.dmg'}]}, set()),
            ({'isDraft': True, 'body': 'Notes', 'assets': []}, {'123'}),
            ({'isDraft': True, 'body': '  ', 'assets': []}, set()),
        ]:
            with self.subTest(draft=draft), self.assertRaises(ValueError):
                prepare.check_candidate_state(draft, '', retained)

    def test_upload_retry_requires_the_retained_run_and_unpublished_draft(self):
        draft = {'isDraft': True, 'body': 'Notes', 'assets': [{'name': 'app.dmg'}]}
        prepare.check_candidate_state(draft, '123', {'123'})
        with self.assertRaises(ValueError):
            prepare.check_candidate_state(draft, '456', {'123'})
        draft['isDraft'] = False
        with self.assertRaises(ValueError):
            prepare.check_candidate_state(draft, '123', {'123'})

    def test_artifacts_from_prs_other_branches_or_other_workflows_are_not_trusted(self):
        trusted = {'path': '.github/workflows/release.yml', 'head_branch': 'main', 'event': 'push'}
        self.assertTrue(prepare.trusted_run(trusted))
        for change in [{'event': 'pull_request'}, {'head_branch': 'feature'}, {'path': '.github/workflows/check.yml'}]:
            self.assertFalse(prepare.trusted_run({**trusted, **change}))

    def test_multiline_notes_are_written_as_output_data(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / 'output'
            notes = 'First line\n$(touch should-not-exist)\n`echo no`\nlast line'
            with patch.dict(os.environ, {'GITHUB_OUTPUT': str(output)}):
                prepare.output(notes=notes)
            lines = output.read_text().splitlines()
            self.assertEqual('\n'.join(lines[1:-1]), notes)
            self.assertEqual(lines[0], 'notes<<' + lines[-1])

    def test_push_without_version_change_does_not_touch_github(self):
        env = {'GITHUB_REF': 'refs/heads/main', 'GITHUB_SHA': 'b' * 40,
               'GITHUB_EVENT_NAME': 'push', 'BEFORE_SHA': 'a' * 40, 'ARTIFACT_RUN_ID': ''}
        with patch.dict(os.environ, env), patch.object(prepare, 'version_at', return_value=('0.5.2', '74')), \
             patch.object(prepare, 'api') as api, patch.object(prepare, 'run') as run, \
             patch.object(prepare, 'output') as output:
            prepare.prepare()
        api.assert_not_called()
        run.assert_not_called()
        output.assert_called_once_with(enabled='false')

    def test_new_version_creates_exact_tag_and_draft_then_passes_notes_to_build(self):
        commit = 'b' * 40
        env = {'GITHUB_REF': 'refs/heads/main', 'GITHUB_SHA': commit,
               'GITHUB_EVENT_NAME': 'push', 'BEFORE_SHA': 'a' * 40,
               'ARTIFACT_RUN_ID': '', 'GH_REPO': 'owner/repo'}
        calls = []
        def run(*args):
            calls.append(args)
            if args[:2] == ('gh', 'api'): return ''
            if args[:3] == ('gh', 'release', 'list'): return '[]'
            if args[:3] == ('gh', 'release', 'create'): return ''
            if args[:3] == ('gh', 'release', 'view'):
                return json.dumps({'isDraft': True, 'body': 'Generated notes', 'assets': []})
            self.fail(str(args))
        with patch.dict(os.environ, env), \
             patch.object(prepare, 'version_at', side_effect=[('0.5.2', '74'), ('0.5.3', '75')]), \
             patch.object(prepare.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)), \
             patch.object(prepare, 'run', side_effect=run), patch.object(prepare, 'api') as api, \
             patch.object(prepare, 'output') as output:
            prepare.prepare()
        api.assert_called_once_with('git/refs', {'ref': 'refs/tags/v0.5.3', 'sha': commit})
        creation = next(call for call in calls if call[:3] == ('gh', 'release', 'create'))
        self.assertIn('--draft', creation)
        self.assertIn('--generate-notes', creation)
        output.assert_called_once_with(enabled='true', tag='v0.5.3', commit=commit,
                                       notes='Generated notes', artifact_run_id='')

    def test_manual_dispatch_outside_main_is_rejected_before_any_command(self):
        with patch.dict(os.environ, {'GITHUB_REF': 'refs/tags/v0.5.2'}), \
             patch.object(prepare, 'run') as run, patch.object(prepare, 'api') as api:
            with self.assertRaisesRegex(ValueError, 'protected main'):
                prepare.prepare()
        run.assert_not_called()
        api.assert_not_called()


if __name__ == '__main__':
    unittest.main()
