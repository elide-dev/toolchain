"""Read public release assets with the normal release jobs' curl client."""
import hashlib
import os
import subprocess


def exists(url):
    result = subprocess.run(['curl', '--disable', '--silent', '--show-error', '--location',
                             '--head', '--max-time', '60', '--output', os.devnull,
                             '--write-out', '%{http_code}', url], capture_output=True, text=True, check=True)
    status = int(result.stdout)
    if status == 404:
        return False
    if 200 <= status < 300:
        return True
    raise RuntimeError(f'Public release lookup returned HTTP {status}: {url}')


def sha256(url):
    digest = hashlib.sha256()
    process = subprocess.Popen(['curl', '--disable', '--fail', '--silent', '--show-error', '--location',
                                '--retry', '3', '--retry-delay', '1', '--max-time', '180', url],
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    for block in iter(lambda: process.stdout.read(1024 * 1024), b''):
        digest.update(block)
    error = process.stderr.read().decode('utf-8', 'replace')
    status = process.wait()
    if status:
        raise RuntimeError(f'Public release download failed with curl status {status}: {error}')
    return digest.hexdigest()
