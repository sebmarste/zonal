#!/usr/bin/env python3
"""Prepare a draft from an approved main version bump, or resume a retained candidate."""
import json
import os
import plistlib
import re
import subprocess
import uuid


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def api(path, body=None):
    command = ['gh', 'api', f"repos/{os.environ['GH_REPO']}/{path}"]
    if body is not None:
        command += ['--method', 'POST', '--input', '-']
    result = subprocess.run(command, input=json.dumps(body) if body is not None else None,
                            text=True, capture_output=True, check=True)
    return json.loads(result.stdout)


def version_at(ref):
    data = plistlib.loads(subprocess.check_output(['git', 'show', f'{ref}:Zonal/Info.plist']))
    return data['CFBundleShortVersionString'], data['CFBundleVersion']


def version_numbers(version):
    require(re.fullmatch(r'\d+\.\d+\.\d+', version), 'Expected a three-part numeric app version')
    return tuple(map(int, version.split('.')))


def bumped_tag(previous, current):
    if previous[0] == current[0]:
        return None
    require(version_numbers(current[0]) > version_numbers(previous[0]),
            'Release version must increase')
    require(current[1].isdigit() and previous[1].isdigit()
            and int(current[1]) > int(previous[1]), 'Release build number must increase')
    return 'v' + current[0]


def trusted_run(data):
    return (data.get('path') == '.github/workflows/release.yml'
            and data.get('head_branch') == 'main'
            and data.get('event') in ('push', 'workflow_dispatch'))


def check_candidate_state(draft, retry, retained):
    require(draft.get('isDraft') is True, 'Published releases cannot be rebuilt or modified')
    require(isinstance(draft.get('body'), str) and draft['body'].strip(), 'Draft notes are empty')
    if retry:
        require(retry in retained, 'Retry must select a retained candidate from this release workflow on main')
    else:
        require(not draft.get('assets'), 'Draft already has assets; retry the original artifact run instead')
        require(not retained, f'Candidate already retained; use artifact_run_id={next(iter(retained), "")}')


def output(**values):
    with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
        for name, value in values.items():
            delimiter = 'zonal_' + uuid.uuid4().hex
            stream.write(f'{name}<<{delimiter}\n{value}\n{delimiter}\n')


def prepare():
    require(os.environ['GITHUB_REF'] == 'refs/heads/main', 'Releases must run from protected main')
    main_commit = os.environ['GITHUB_SHA']
    retry = os.environ.get('ARTIFACT_RUN_ID', '')
    require(not retry or retry.isdigit(), 'Invalid artifact run ID')
    if os.environ['GITHUB_EVENT_NAME'] == 'push':
        before = os.environ['BEFORE_SHA']
        require(re.fullmatch(r'[0-9a-f]{40}', before) and set(before) != {'0'},
                'A previous main commit is required')
        tag = bumped_tag(version_at(before), version_at(main_commit))
        if tag is None:
            output(enabled='false')
            print('App version unchanged; no release.')
            return
        commit = main_commit
        existing = subprocess.run(['git', 'rev-parse', '--verify', f'refs/tags/{tag}^{{commit}}'],
                                  capture_output=True, text=True)
        if existing.returncode == 0:
            require(existing.stdout.strip() == commit, 'Version tag already belongs to another commit')
        else:
            api('git/refs', {'ref': f'refs/tags/{tag}', 'sha': commit})
    else:
        require(os.environ['GITHUB_EVENT_NAME'] == 'workflow_dispatch', 'Unsupported release event')
        tag = os.environ.get('RELEASE_TAG', '')
        require(re.fullmatch(r'v\d+\.\d+\.\d+', tag), 'Select an existing version tag')
        commit = run('git', 'rev-parse', f'refs/tags/{tag}^{{commit}}')
        subprocess.run(['git', 'merge-base', '--is-ancestor', commit, main_commit], check=True)
        require(tag == 'v' + version_at(commit)[0], 'Tag must match its app version')

    # An Actions artifact is a recovery copy, not permission to rebuild the same version.
    ids = run('gh', 'api', '--paginate',
              f"repos/{os.environ['GH_REPO']}/actions/artifacts?name=candidate-{tag}&per_page=100",
              '--jq', '.artifacts[] | select(.expired == false) | .workflow_run.id').splitlines()
    retained = {run_id for run_id in ids if trusted_run(api(f'actions/runs/{run_id}'))}
    drafts = json.loads(run('gh', 'release', 'list', '--limit', '1000', '--json', 'tagName'))
    if tag not in {draft['tagName'] for draft in drafts}:
        require(not retry and not retained, 'Restore the original draft before retrying its candidate')
        run('gh', 'release', 'create', tag, '--verify-tag', '--draft', '--prerelease',
            '--title', f'Zonal {tag[1:]} public beta', '--generate-notes')
    draft = json.loads(run('gh', 'release', 'view', tag, '--json', 'isDraft,body,assets'))
    check_candidate_state(draft, retry, retained)
    output(enabled='true', tag=tag, commit=commit, notes=draft['body'], artifact_run_id=retry)
    print(f'Prepared {tag} at {commit}; publication follows successful artifact verification.')


if __name__ == '__main__':
    try:
        prepare()
    except (ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
