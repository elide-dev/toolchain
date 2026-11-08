# Contributor agreement

Elide Toolchain accepts first-party contributions under **Apache-2.0 OR MIT**, at
the recipient's option. By intentionally submitting a contribution for inclusion,
you offer it under both license alternatives in [LICENSE](LICENSE), including the
applicable Apache-2.0 patent terms. You retain your copyright. This project does
not require copyright assignment or a separate signed CLA.

Submit only work you are authorized to contribute. Preserve third-party copyright
and license notices and identify externally sourced material in your pull request.
Third-party code and upstream patch context retain their own terms; the root
license does not relicense them. See [THIRD_PARTY.md](THIRD_PARTY.md).

## Developer Certificate of Origin

New non-merge commits submitted after this policy is adopted must carry a
`Signed-off-by: Name <email>` trailer certifying the unmodified
[Developer Certificate of Origin 1.1](DCO). Read the certificate before signing.
Use your own name and an email address you control (a GitHub noreply address is
acceptable). The signer must be the commit's author or committer. The sign-off is
a public certification; it is distinct from a cryptographic Git commit signature.
Both can be required by repository policy.

```sh
git commit -s
# Add your own sign-off to your latest unpublished commit, if you can certify it:
git commit --amend --no-edit -s
```

Do not sign someone else's name. Preserve existing author attribution and
sign-offs when forwarding or revising a contribution. For a multi-commit PR,
every new non-merge commit needs a qualifying sign-off; coordinate any necessary
history edits with collaborators. GitHub's generated integration merge commits
are excluded from this trailer check. No historical sign-offs are inferred or
retroactively added by automation.

The `Repository hygiene` check validates sign-off trailers on PR and merge-queue
commit ranges. Missing or malformed trailers fail the check. Automated dependency
updates are subject to the same rule: a bot may emit its own valid sign-off when
configured to do so, or a responsible maintainer may review the work and certify
it as committer. Do not add an automatic blanket bypass for bots.

## AI-assisted contributions

Tools may help prepare code, tests, documentation, and reviews. The submitting
person remains responsible for understanding and testing the result, checking
its provenance and license compatibility, and making any DCO certification they
can truthfully make. An agent must not invent a contributor's identity, sign-off,
review, test result, or legal authorization. Disclose material generated or copied
content and its source when relevant to review; never submit private inputs or
credentials with it.

## Review and enforcement

Maintainers review contribution rights, attribution, behavior, and tests alongside
normal technical review. They may request provenance details or decline material
whose rights cannot be established. One approving reviewer is required by the
proposed repository rules; this agreement adds no multi-reviewer requirement.
Use [CONTRIBUTING.md](CONTRIBUTING.md) for setup and coding standards and follow
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) in project spaces.
