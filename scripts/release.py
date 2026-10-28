#!/usr/bin/env python3
"""Build a notarized candidate once; retain or re-upload exactly those bytes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
from contextlib import contextmanager
import plistlib
import re
import subprocess
import tempfile
import sys

ROOT = Path(__file__).resolve().parent.parent
BUNDLE_ID = "com.sebmarste.zonal"


def run(*args, capture=False):
    return subprocess.run([str(a) for a in args], check=True, cwd=ROOT,
                          stdout=subprocess.PIPE if capture else None,
                          text=True).stdout


def digest(path):
    with open(path, 'rb') as stream:
        hasher = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            hasher.update(chunk)
        return hasher.hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def version_info():
    with open(ROOT / 'Zonal/Info.plist', 'rb') as stream:
        info = plistlib.load(stream)
    return info['CFBundleShortVersionString'], info['CFBundleVersion']


def validate_tag(tag):
    require(re.fullmatch(r'v\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?', tag), 'Invalid version tag')


def source_commit(tag):
    validate_tag(tag)
    commit = run('git', 'rev-parse', 'HEAD', capture=True).strip()
    require(run('git', 'rev-parse', f'refs/tags/{tag}^{{commit}}', capture=True).strip() == commit,
            'Check out the exact release tag before building or uploading')
    return commit


def signature(app, team):
    run('codesign', '--verify', '--deep', '--strict', app)
    result = subprocess.run(['codesign', '-d', '--verbose=4', str(app)], check=True,
                            capture_output=True, text=True).stderr
    require(f'Identifier={BUNDLE_ID}\n' in result and f'TeamIdentifier={team}\n' in result,
            'Unexpected bundle or signing team')
    require('Authority=Developer ID Application:' in result, 'Developer ID Application signature required')
    require('runtime' in result and 'Timestamp=' in result, 'Hardened Runtime and timestamp required')
    entitlements = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(app)],
                                 check=True, capture_output=True).stdout
    if entitlements.strip():
        require(not plistlib.loads(entitlements).get('com.apple.security.get-task-allow'),
                'Release must not enable get-task-allow')
    require(set(run('lipo', '-archs', app / 'Contents/MacOS/Zonal', capture=True).split()) == {'arm64', 'x86_64'},
            'Both arm64 and x86_64 slices are required')


def zip_bundle(source, destination):
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', source, destination)
    run('unzip', '-tq', destination)


def build_dmg(app, destination):
    require(not destination.exists(), 'Never overwrite a disk image')
    with tempfile.TemporaryDirectory(prefix='zonal-dmg-tools-') as folder:
        run(sys.executable, '-m', 'venv', folder)
        python = Path(folder) / 'bin/python'
        run(python, '-m', 'pip', 'install', '--disable-pip-version-check', '--require-hashes',
            '--only-binary=:all:', '-r', ROOT / '.github/scripts/dmg-requirements.txt')
        run(python, ROOT / '.github/scripts/dmg.py', app, destination)


def notarize(submission, evidence, label):
    auth = ['--keychain-profile', os.environ.get('ZONAL_NOTARY_PROFILE', 'zonal-release')]
    if os.environ.get('ZONAL_NOTARY_KEYCHAIN'):
        auth += ['--keychain', os.environ['ZONAL_NOTARY_KEYCHAIN']]
    result = subprocess.run(['xcrun', 'notarytool', 'submit', str(submission), *auth,
                             '--wait', '--timeout', '20m', '--output-format', 'json'],
                            capture_output=True, text=True)
    (evidence / f'{label}-notarization.json').write_text(result.stdout)
    (evidence / f'{label}-notarization-stderr.txt').write_text(result.stderr)
    # Preserve even a rejected/timed-out submission ID so maintainers can retrieve its log.
    notarization = json.loads(result.stdout)
    run('xcrun', 'notarytool', 'log', notarization['id'], *auth, evidence / f'{label}-notarization-log.json')
    require(result.returncode == 0 and notarization['status'] == 'Accepted', 'Notarization was not accepted; inspect retained evidence')


@contextmanager
def mounted_dmg(path):
    with tempfile.TemporaryDirectory(prefix='zonal-dmg-verify-') as folder:
        mount = Path(folder) / 'volume'
        run('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, path)
        try:
            require((mount / 'Zonal.app').is_dir() and not (mount / 'Zonal.app').is_symlink(),
                    'Disk image must contain Zonal.app')
            require((mount / 'Applications').is_symlink()
                    and os.readlink(mount / 'Applications') == '/Applications',
                    'Disk image must link to /Applications')
            yield mount
        finally:
            run('hdiutil', 'detach', mount)


def draft_notes(tag):
    validate_tag(tag)
    draft = json.loads(run('gh', 'release', 'view', tag, '--json', 'isDraft,body', capture=True))
    require(draft.get('isDraft') is True, 'Reviewed draft release required before building')
    body = draft.get('body')
    require(isinstance(body, str) and body.strip(), 'Nonempty reviewed draft notes required')
    return body.rstrip() + '\n'


def build(output, tag, notes=None):
    version, build_number = version_info()
    require(tag == f'v{version}', 'Tag must match Info.plist version')
    commit = source_commit(tag)
    require(not run('git', 'status', '--porcelain', capture=True).strip(), 'Commit changes before building')
    identity = os.environ.get('ZONAL_SIGN_IDENTITY', '')
    team = os.environ.get('ZONAL_TEAM_ID', '')
    require(identity.startswith('Developer ID Application:') and re.fullmatch(r'[A-Z0-9]{10}', team),
            'Set ZONAL_SIGN_IDENTITY and ZONAL_TEAM_ID for Developer ID signing')
    require(identity in run('security', 'find-identity', '-v', '-p', 'codesigning', capture=True),
            'Developer ID certificate and private key are not available')
    if notes is None:
        notes_text = draft_notes(tag)
    else:
        require(notes.is_file() and notes.read_text().strip(), 'Nonempty curated release notes required')
        notes_text = notes.read_text()
    require(not output.exists(), 'Use a new output directory; never overwrite a candidate')
    output.mkdir(parents=True)
    (output / 'release-notes.md').write_text(notes_text)
    run(ROOT / 'scripts/check')
    evidence = output / 'evidence'
    evidence.mkdir()
    archive = evidence / 'Zonal.xcarchive'
    with tempfile.TemporaryDirectory(prefix='zonal-release-build-') as derived:
        run('xcodebuild', '-project', ROOT / 'Zonal.xcodeproj', '-scheme', 'Zonal',
            '-configuration', 'Release', '-derivedDataPath', derived, '-archivePath', archive,
            'ARCHS=arm64 x86_64', 'ONLY_ACTIVE_ARCH=NO', 'SKIP_INSTALL=NO',
            'CODE_SIGN_STYLE=Manual', f'CODE_SIGN_IDENTITY={identity}', f'DEVELOPMENT_TEAM={team}',
            'OTHER_CODE_SIGN_FLAGS=--timestamp', 'archive')
    app = archive / 'Products/Applications/Zonal.app'
    signature(app, team)
    with open(app / 'Contents/Info.plist', 'rb') as stream:
        info = plistlib.load(stream)
    require((info['CFBundleShortVersionString'], info['CFBundleVersion']) == (version, build_number),
            'Built version does not match source')
    binary_uuids = run('dwarfdump', '--uuid', app / 'Contents/MacOS/Zonal', capture=True)
    symbol_uuids = run('dwarfdump', '--uuid', archive / 'dSYMs/Zonal.app.dSYM', capture=True)
    uuid_pattern = r'UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)'
    require(set(re.findall(uuid_pattern, binary_uuids)) == set(re.findall(uuid_pattern, symbol_uuids))
            and len(re.findall(uuid_pattern, binary_uuids)) == 2, 'Missing or mismatched dSYMs')
    (evidence / 'uuids.txt').write_text(binary_uuids + symbol_uuids)
    (evidence / 'toolchain.txt').write_text(run('xcodebuild', '-version', capture=True)
                                          + run('xcrun', '--show-sdk-version', capture=True))
    submission = output / 'submission.zip'
    zip_bundle(app, submission)
    notarize(submission, evidence, 'app')
    run('xcrun', 'stapler', 'staple', app)
    run('xcrun', 'stapler', 'validate', app)
    signature(app, team)
    run('spctl', '--assess', '--type', 'execute', '--verbose=2', app)
    metadata = dict(schemaVersion=1, tag=tag, version=version, build=build_number, commit=commit, team=team)
    (evidence / 'provenance.json').write_text(json.dumps(metadata, indent=2) + '\n')
    dmg = output / f'Zonal-{version}.dmg'
    build_dmg(app, dmg)
    run('codesign', '--sign', identity, '--timestamp', '--identifier', f'{BUNDLE_ID}.dmg', dmg)
    notarize(dmg, evidence, 'dmg')
    run('xcrun', 'stapler', 'staple', dmg)
    zip_bundle(evidence, output / f'Zonal-{version}-evidence.zip')
    files = [f'Zonal-{version}.dmg', f'Zonal-{version}-evidence.zip', 'release-notes.md']
    metadata['artifacts'] = {name: digest(output / name) for name in files}
    (output / 'manifest.json').write_text(json.dumps(metadata, indent=2) + '\n')
    (output / 'SHA256SUMS').write_text(''.join(f'{digest(output / name)}  {name}\n'
                                              for name in [*files, 'manifest.json']))
    submission.unlink()
    verify(output, tag, assess=True)
    print(f'Verified candidate retained at {output}; nothing published.')


def validate_manifest(data, tag):
    validate_tag(tag)
    require(data.get('schemaVersion') == 1 and data.get('tag') == tag, 'Unexpected manifest/tag')
    require(tag == 'v' + data.get('version', ''), 'Version/tag mismatch')
    require(re.fullmatch(r'[0-9a-f]{40}', data.get('commit', '')), 'Invalid source commit')
    require(re.fullmatch(r'[A-Z0-9]{10}', data.get('team', '')), 'Invalid signing team')
    version = data['version']
    expected = {f'Zonal-{version}.dmg', f'Zonal-{version}-evidence.zip', 'release-notes.md'}
    require(set(data.get('artifacts', {})) == expected, 'Unexpected or missing artifacts')
    require(all(re.fullmatch(r'[0-9a-f]{64}', value) for value in data['artifacts'].values()),
            'Invalid SHA-256')


def verify(output, tag, assess=False):
    data = json.loads((output / 'manifest.json').read_text())
    validate_manifest(data, tag)
    for name, expected in data['artifacts'].items():
        require(digest(output / name) == expected, f'Artifact mismatch: {name}')
    sums = ''.join(f'{digest(output / name)}  {name}\n' for name in [*data['artifacts'], 'manifest.json'])
    require((output / 'SHA256SUMS').read_text() == sums, 'Checksum file mismatch')
    if assess:
        assess_dmg(output / f"Zonal-{data['version']}.dmg", data['team'], data['version'], data['build'])
    return data


def assess_dmg(dmg, team, version, build_number):
    run('codesign', '--verify', '--strict', dmg)
    details = subprocess.run(['codesign', '-d', '--verbose=4', str(dmg)], check=True,
                             capture_output=True, text=True).stderr
    require(f"TeamIdentifier={team}\n" in details
            and f'Identifier={BUNDLE_ID}.dmg\n' in details
            and 'Authority=Developer ID Application:' in details and 'Timestamp=' in details,
            'Unexpected disk image signature')
    run('xcrun', 'stapler', 'validate', dmg)
    run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=2', dmg)
    with mounted_dmg(dmg) as mount:
        app = mount / 'Zonal.app'
        signature(app, team)
        with open(app / 'Contents/Info.plist', 'rb') as stream:
            info = plistlib.load(stream)
        require((info['CFBundleShortVersionString'], info['CFBundleVersion']) == (version, build_number),
                'Packaged version/build differs from manifest')
        run('xcrun', 'stapler', 'validate', app)
        run('spctl', '--assess', '--type', 'execute', '--verbose=2', app)


def upload(output, tag):
    data = verify(output, tag, assess=True)
    require(source_commit(tag) == data['commit'], 'Candidate was built from another source commit')
    # Verify the remote tag, including annotated tags, before attaching any bytes.
    refs = run('git', 'ls-remote', 'origin', f'refs/tags/{tag}', f'refs/tags/{tag}^{{}}', capture=True).splitlines()
    peeled = {line.split()[1]: line.split()[0] for line in refs}
    require(peeled.get(f'refs/tags/{tag}^{{}}', peeled.get(f'refs/tags/{tag}')) == data['commit'],
            'Remote tag is absent or points to another commit')
    result = subprocess.run(['gh', 'release', 'view', tag, '--json', 'isDraft,assets'], cwd=ROOT,
                            capture_output=True, text=True)
    if result.returncode:
        run('gh', 'release', 'create', tag, '--verify-tag', '--draft', '--prerelease',
            '--title', f"Zonal {data['version']} public beta", '--notes-file', output / 'release-notes.md')
    release = json.loads(run('gh', 'release', 'view', tag, '--json', 'isDraft,assets,body', capture=True))
    require(release['isDraft'], 'Refusing to modify a published release')
    require(release.get('body', '').strip() == (output / 'release-notes.md').read_text().strip(),
            'Draft notes differ from archived candidate; restore the archived text before uploading')
    existing = {asset['name'] for asset in release['assets']}
    names = {*data['artifacts'], 'manifest.json', 'SHA256SUMS'}
    require(existing <= names, 'Draft contains unexpected assets; refusing publication')
    for name in [*data['artifacts'], 'manifest.json', 'SHA256SUMS']:
        if name not in existing:
            run('gh', 'release', 'upload', tag, output / name)
        # Verify uploaded bytes too, before CI makes the draft public.
        with tempfile.TemporaryDirectory(prefix='zonal-release-existing-') as folder:
            run('gh', 'release', 'download', tag, '--pattern', name, '--dir', folder)
            require(digest(Path(folder) / name) == digest(output / name),
                    f'Remote asset differs: {name}; refusing publication or overwrite')
    print(f'Draft {tag} retained with symbols and evidence. All remote assets verified; ready for publication.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['build', 'verify', 'upload'])
    parser.add_argument('directory', type=Path)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--notes', type=Path)
    args = parser.parse_args()
    if args.action == 'build':
        build(args.directory.resolve(), args.tag, args.notes.resolve() if args.notes else None)
    elif args.action == 'verify':
        verify(args.directory.resolve(), args.tag, assess=True)
    else:
        upload(args.directory.resolve(), args.tag)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
