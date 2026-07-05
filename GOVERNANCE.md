# Governance

This document describes, honestly, how decisions are made in cce-ruby.

## Model: single maintainer (BDFL)

cce-ruby is a solo project. [David Silva](https://davidslv.uk) (GitHub
[@davidslv](https://github.com/davidslv)) is the sole maintainer and acts as
Benevolent Dictator For Life (BDFL): he has final say on all decisions —
scope, design, what gets merged, and what gets released.

This is a deliberate, honest description of the current reality, not an
aspiration to a larger structure. There is no committee, no voting, and no
service-level agreement.

## The spec is the constitution

Because CCE is a **clean-room, spec-first** project, [`SPEC.md`](SPEC.md) is the
highest authority on *behaviour*. The rules that follow from this constrain even
the maintainer:

- A change that alters observable behaviour is a **spec change**, and must be
  reflected in [`SPEC.md`](SPEC.md), with the reasoning recorded in
  [`docs/DECISIONS.md`](docs/DECISIONS.md).
- The sibling Rust implementation ([davidslv/cce-rust](https://github.com/davidslv/cce-rust))
  is built from the **same** spec. Divergence in the spec is a cross-project
  decision and should not be made lightly.
- Conformance output (`conformance.json`) must not drift except as an
  intentional, versioned spec revision.

## How decisions are made

1. **Proposals** start as GitHub issues. For anything non-trivial, open an issue
   before writing code (see [`CONTRIBUTING.md`](CONTRIBUTING.md)).
2. **Discussion** happens in the open on that issue.
3. **The maintainer decides.** Decisions favour: fidelity to the spec,
   determinism, simplicity, and keeping the test suite green.
4. **Records.** Architectural and ambiguity-resolving decisions are written down
   in [`docs/DECISIONS.md`](docs/DECISIONS.md); user-visible changes go in
   [`CHANGELOG.md`](CHANGELOG.md).

## Releases

Versioning follows [SemVer](https://semver.org/). The maintainer cuts releases;
each is recorded in [`CHANGELOG.md`](CHANGELOG.md). Breaking behaviour changes
imply a spec revision and a major version.

## How this could evolve

If the project attracts sustained contribution, governance can grow to match:

- Trusted, consistent contributors may be invited to become maintainers (see
  [`MAINTAINERS.md`](MAINTAINERS.md) for the path).
- With more than one maintainer, this document would be updated to describe how
  they share responsibility and resolve disagreement.

Until then, the honest description stands: one maintainer, best-effort,
spec-first.
