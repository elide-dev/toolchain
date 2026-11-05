"""Read one exact, immutable producer artifact using the existing CI token."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.request
import zipfile


def artifact_metadata(package, repository):
    artifact_id = package['artifactId']
    if type(artifact_id) is not int or artifact_id <= 0:
        raise ValueError('Expected an exact artifact ID')
    request = urllib.request.Request(
        f'https://api.github.com/repos/{repository}/actions/artifacts/{artifact_id}',
        headers={'Authorization': 'Bearer ' + os.environ['GH_TOKEN']})
    with urllib.request.urlopen(request) as response:
        artifact = json.load(response)
    if (artifact['name'] != package['artifact'] or artifact['expired']
            or artifact['workflow_run']['id'] != package['run']
            or artifact['workflow_run']['head_sha'] != package['commit']):
        raise ValueError('Artifact ID does not belong to the exact producer build')
    return artifact


def download_artifact(package, repository, destination):
    artifact = artifact_metadata(package, repository)
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryFile() as stream:
        subprocess.run(['gh', 'api', f'repos/{repository}/actions/artifacts/{artifact["id"]}/zip'],
                       stdout=stream, check=True)
        stream.seek(0)
        expected = artifact.get('digest')
        if expected:
            if not re.fullmatch('sha256:[0-9a-f]{64}', expected):
                raise ValueError('Unexpected GitHub artifact digest')
            if 'sha256:' + hashlib.file_digest(stream, 'sha256').hexdigest() != expected:
                raise ValueError('Artifact archive differs from its GitHub digest')
        stream.seek(0)
        with zipfile.ZipFile(stream) as archive:
            for member in archive.infolist():
                path = Path(member.filename)
                if path.is_absolute() or path.drive or '..' in path.parts or '\\' in member.filename or re.match('[A-Za-z]:', member.filename):
                    raise ValueError('Expected a relative artifact member')
            archive.extractall(destination)  # Also verifies every ZIP member CRC.
    return artifact
