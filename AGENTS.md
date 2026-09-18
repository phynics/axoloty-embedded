# axoloty-embedded instructions

## Related repositories

[`phynics/axoloty`](https://github.com/phynics/axoloty) is Core. It owns the
portable wire, object model, protocol, Coaty models, and static runtime, the
[embedded consumer contract](https://github.com/phynics/axoloty/blob/main/docs/embedded-consumer-contract.md)
this repository consumes, and the hardware-free gates that prove those
packages stay Embedded-Swift compatible. Its
[`AGENTS.md`](https://github.com/phynics/axoloty/blob/main/AGENTS.md) governs
changes there.

This repository owns concrete firmware. The split is tracked by
[phynics/axoloty#845](https://github.com/phynics/axoloty/issues/845).

## Jurisdiction

This guide applies to the whole repository. It is the contributor policy for
firmware composition and device qualification. Axoloty's own `AGENTS.md`
governs the Core checkout and does not apply to files here.

## Ownership boundary

This repository owns applications, platform and SDK integration, embedded
transport backends, profiles, device qualification, and firmware releases.

[Axoloty](https://github.com/phynics/axoloty) owns the portable wire, object
model, protocol, Coaty models, and static runtime, plus the Embedded-Swift
compatibility contract and its hardware-free gates.

A change that alters protocol semantics, wire format, or portable runtime
behavior belongs in `phynics/axoloty`, not here. Open it there and raise the
lock afterwards.

## Invariants

- Portable Axoloty source is never copied into this repository. The portable
  packages are compiled in place from the locked checkout.
- The lock's commit SHA is authoritative. A build that cannot name its exact
  Core commit is not a release build.
- Core is reached only through `Tools/prepare-core.sh` and the preparation
  report it writes. Never read Axoloty's root `.build`, its `Tests/` tree, or
  a parent directory.
- An application names no board, SDK, or broker. A transport contains no
  protocol rule.
- A profile claims a Core revision only with device evidence for that
  revision. Compatibility is per profile.
- Migration from Axoloty is behavior-preserving. File unrelated discoveries as
  their own issues instead of fixing them inside a migration change.

## Supported workflow

```bash
Tools/prepare-core.sh                                  # locked Core
AXOLOTY_SOURCE_DIR=/abs/path/to/axoloty Tools/prepare-core.sh   # local Core
AXOLOTY_STRICT_CORE=1 Tools/prepare-core.sh            # as CI runs it
```

Strict mode is the default under CI and refuses a dirty or off-lock Core
checkout. Never disable it to make a release build pass.

## GitHub-centered work

- Fetch and compare `origin/main` before branching.
- Keep designs, plans, and decisions in GitHub issues or comments.
- One fix per PR, opened against `main` with `Closes #<issue-number>`.
- A change that spans Core and firmware is two PRs: Core first, then the lock
  raise here, each independently reviewable.
- Use Conventional Commits with the configured identity and no bot co-author
  trailer.
- Ask before creating an issue the user did not request.

## Device work

Hardware runs are evidence, not decoration. Record the device, the firmware
artifact checksum, the Core commit, and the smoke protocol and its result with
any claim that a profile works. A qualification claim without that evidence is
not accepted.
