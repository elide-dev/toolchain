"""Stage the already qualified, complete native release without rebuilding it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import urllib.error
import urllib.request
from public_release_http import exists as public_exists, sha256 as public_sha256
from producer_artifact import download_artifact

SOURCE = 'e5365e07215ccfe81409ab5652d05a6c98c14606'
RUNS = {platform: 41974944319 for platform in ['linux-amd64', 'linux-arm64', 'darwin-arm64']}
VERSION = '2026.11.2'
REPOSITORY = 'elide-dev/toolchain'


def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', f'repos/{REPOSITORY}/{path}'], text=True))


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def package(run, commit, name):
    artifacts = api(f'actions/runs/{run}/artifacts?per_page=100')['artifacts']
    artifact = max((a for a in artifacts if a['name'] == name and not a['expired']), key=lambda a: a['id'])
    return {'run': run, 'commit': commit, 'artifact': name, 'artifactId': artifact['id']}


def stage(output, qualification):
    for run in set(RUNS.values()):
        build = api(f'actions/runs/{run}')
        assert build['conclusion'] == 'success' and build['head_sha'] == SOURCE
    check = api(f'actions/runs/{qualification}')
    assert check['conclusion'] == 'success' and check['event'] == 'workflow_dispatch'
    assert check['path'] == '.github/workflows/debug-quality-qualification.yml'
    downloads = output.parent / 'producer-downloads'
    proof = package(qualification, check['head_sha'], 'debug-quality-action-provenance')
    download_artifact(proof, REPOSITORY, downloads / 'proof')
    evidence = json.loads((downloads / 'proof/provenance.json').read_text())
    assert evidence == {'source': SOURCE, 'runs': RUNS}
    output.mkdir(parents=True)
    packages = []
    for platform in ['linux-amd64', 'linux-arm64', 'darwin-arm64']:
        item = package(RUNS[platform], SOURCE, 'elide-toolchain-' + platform)
        folder = downloads / platform
        download_artifact(item, REPOSITORY, folder)
        for path in folder.iterdir():
            assert path.is_file(), path
            assert not (output / path.name).exists(), path
            path.rename(output / path.name)
        packages.append(item)
    expected = {f'elide-toolchain-{VERSION}-{p}.tar.xz' for p in ['linux-amd64', 'linux-arm64', 'darwin-arm64']}
    expected |= {f'elide-toolchain-{VERSION}-linux-amd64-sanitizer-{s}.tar.xz' for s in ['asan', 'tsan', 'msan']}
    assert {p.name for p in output.glob('*.tar.xz')} == expected
    for name in expected:
        assert (output / (name + '.sha256')).read_text().split()[0] == sha(output / name), name
    files = {p.name: sha(p) for p in sorted(output.iterdir())}
    (output.parent / 'manifest.json').write_text(json.dumps({'source': SOURCE, 'version': VERSION,
        'qualification': proof, 'packages': packages, 'files': files}, indent=2) + '\n')
    print('Verified complete exact release:', len(expected), 'archives;', len(files), 'assets')


def verify(output, require_unpublished, remote=False):
    manifest = json.loads((output.parent / 'manifest.json').read_text())
    assert manifest['source'] == SOURCE and manifest['version'] == VERSION
    assert {p.name for p in output.iterdir()} == set(manifest['files'])
    for name, digest in manifest['files'].items():
        assert Path(name).name == name and sha(output / name) == digest, name
        if remote:
            for base in [f'https://github.com/{REPOSITORY}/releases/download/v{VERSION}/',
                         f'https://static.elideusercontent.com/toolchain/{VERSION}/']:
                assert public_sha256(base + name) == digest, base + name
    if require_unpublished:
        for suffix in ['releases/tags/', 'git/ref/tags/']:
            request = urllib.request.Request(f'https://api.github.com/repos/{REPOSITORY}/{suffix}v{VERSION}',
                headers={'Authorization': 'Bearer ' + os.environ['GH_TOKEN']})
            try:
                with urllib.request.urlopen(request):
                    raise RuntimeError('Release or tag exists; refuse to overwrite it')
            except urllib.error.HTTPError as error:
                if error.code != 404:
                    raise
        if public_exists(f'https://static.elideusercontent.com/toolchain/{VERSION}/elide-toolchain-{VERSION}-linux-amd64.tar.xz'):
            raise RuntimeError('Mirror version exists; refuse to overwrite it')
    print('Verified exact staged bytes:', len(manifest['files']), 'assets')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['stage', 'verify', 'verify-remote'])
    parser.add_argument('output', type=Path)
    parser.add_argument('--qualification', type=int)
    parser.add_argument('--require-unpublished', action='store_true')
    args = parser.parse_args()
    if args.mode == 'stage':
        assert args.qualification
        stage(args.output, args.qualification)
    else:
        verify(args.output, args.require_unpublished, args.mode == 'verify-remote')
