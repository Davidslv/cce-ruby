<!--
Thanks for contributing to cce-ruby! Please fill this in.
For anything larger than a small fix, open an issue first (see CONTRIBUTING.md).
-->

## Summary

<!-- What does this change do, and why? -->

## Related issue

<!-- e.g. Closes #123 -->

## Type of change

- [ ] Bug fix (behaviour was wrong vs. SPEC.md)
- [ ] Feature (new capability)
- [ ] Documentation only
- [ ] Refactor / internal (no behaviour change)
- [ ] Intentional spec revision (SPEC.md updated, version bump)

## Quality gates

<!-- All boxes must be checked before this PR can be merged. -->

- [ ] `bundle exec rake test` passes locally (0 failures, 0 errors)
- [ ] New/changed behaviour is covered by tests, written test-first
- [ ] Line coverage is maintained (not below the ~94% baseline)
- [ ] Docs updated where behaviour, flags, or architecture changed
      (`docs/`, and `SPEC.md` / `docs/DECISIONS.md` for normative changes)
- [ ] `CHANGELOG.md` `Unreleased` section updated for any user-visible change
- [ ] **Conformance unchanged** — `bundle exec bin/cce conformance test/fixture`
      still produces the committed `conformance.json` byte-for-byte
      *(or this is an intentional, documented spec revision)*

## Notes for reviewers

<!-- Anything worth calling out: trade-offs, follow-ups, screenshots, etc. -->
