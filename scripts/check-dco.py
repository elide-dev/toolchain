# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
"""Validate DCO trailers on new non-merge commits; never modify commit history.

With --message-file, check the message of the commit being written instead (hk.pkl's
commit-msg hook), against the author and committer identities Git will record."""
import argparse
import os
import re
import subprocess
import sys


def git(*args, input_text=None):
    return subprocess.check_output(
        ['git', *args], input=input_text, text=True, encoding='utf-8', errors='replace',
    ).strip()


def valid_signoff(message, author, committer):
    trailers = git('interpret-trailers', '--parse', '--no-divider', input_text=message)
    identities = {author.casefold(), committer.casefold()}
    for line in trailers.splitlines():
        key, separator, value = line.partition(':')
        if separator and key.casefold() == 'signed-off-by':
            identity = value.strip()
            if re.fullmatch(r'[^<>\n]+ <[^\s<>@]+@[^\s<>@]+>', identity):
                if identity.casefold() in identities:
                    return True
    return False


def check(base, head):
    # These values come from event SHA fields, not ref names or PR text.
    for label, value in (('base', base), ('head', head)):
        if not re.fullmatch(r'[0-9a-fA-F]{40}', value) or set(value) == {'0'}:
            raise ValueError(f'{label} must be a nonzero full commit SHA')
        git('cat-file', '-e', value + '^{commit}')
    commits = git('rev-list', '--no-merges', f'{base}..{head}').splitlines()
    failures = []
    for commit in commits:
        author, committer, message = git('show', '-s', '--format=%an <%ae>%x00%cn <%ce>%x00%B', commit).split('\0', 2)
        if not valid_signoff(message, author, committer):
            failures.append(commit)
    if failures:
        raise ValueError('Missing valid author/committer Signed-off-by trailer: ' + ', '.join(failures))
    print(f'DCO: {len(commits)} new non-merge commits checked')


SCISSORS = re.compile(r'^\S+ -+ >8 -+$', re.MULTILINE)
IDENT = re.compile(r'^(.*>) \d+ [+-]\d{4}$')


def identity(var):
    """`git var` identity without its timestamp: 'Name <email>'."""
    value = git('var', var)
    match = IDENT.fullmatch(value)
    return match.group(1) if match else value


def check_message_file(path):
    # A merge commit (`git merge`, or `git commit` concluding one) carries no new work.
    if os.path.exists(git('rev-parse', '--git-path', 'MERGE_HEAD')):
        return
    with open(path, encoding='utf-8', errors='replace') as file:
        message = file.read()
    # `git commit -v` appends the diff below a scissors line; comments are not part of the message.
    message = SCISSORS.split(message, 1)[0]
    message = git('stripspace', '--strip-comments', input_text=message)
    author, committer = identity('GIT_AUTHOR_IDENT'), identity('GIT_COMMITTER_IDENT')
    if not valid_signoff(message, author, committer):
        raise ValueError(f'commit message has no Signed-off-by for {author}'
                         + ('' if author == committer else f' or {committer}')
                         + '. Certify the DCO (see CONTRIBUTING.md) and commit with `git commit -s`'
                         + ' (or `git commit --amend -s`).')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', default=os.environ.get('DCO_BASE', ''))
    parser.add_argument('--head', default=os.environ.get('DCO_HEAD', ''))
    parser.add_argument('--message-file', help='check this commit message (commit-msg hook) instead of a range')
    args = parser.parse_args()
    try:
        if args.message_file:
            check_message_file(args.message_file)
        else:
            check(args.base, args.head)
    except (ValueError, subprocess.CalledProcessError) as error:
        print(f'DCO check failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
