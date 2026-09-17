# Workflow

This repository is worked on from three different places, and they do not have
the same capabilities:

- a checkout with no embedded toolchain at all;
- CI, with a toolchain and no board;
- a bench, with a board attached.

The workflow below is written so that the same commands work in all three, and
so that a report from one is never mistaken for a report from another.

## The one entry point

```bash
Tools/verify.sh
```

Run it before every commit. It runs every tier that this machine can run and
prints a summary. Paste that summary into the issue or PR unedited.

```bash
Tools/verify.sh --tier repo          # only the hardware-free invariants
Tools/verify.sh --require core       # fail unless Core preparation can run
Tools/verify.sh --profile esp32c6-mqtt
```

## Capability tiers

| Tier | Proves | Needs |
|---|---|---|
| `repo` | ownership invariants and repository shape | nothing |
| `core` | the locked Axoloty revision prepares cleanly | `swift`, network |
| `build` | each profile produces a firmware image | the platform toolchain |
| `device` | the image boots and passes its smoke protocol | a physical board |

A tier whose capability is absent prints `UNAVAILABLE` with the reason and is
reported as `SKIP`, never as a pass.

**`SKIP` is not a pass.** This is the rule that matters most here. Saying "the
firmware builds" when `build` reported `SKIP` is a false claim about the
product, and it is the single failure this workflow exists to prevent. If you
did not run a tier, write that you did not run it, and say why.

## What `repo` enforces

`Tools/check-invariants.sh` is the enforceable half of `AGENTS.md`. It checks:

1. the lock is well formed and its revision is a full 40-character SHA;
2. no portable Core source is copied here, by directory name, by local target
   declaration, and by filename comparison when a Core checkout is reachable;
3. no application names a board, SDK, or broker;
4. no transport states a protocol rule;
5. no platform states a protocol rule;
6. nothing discovers Core by parent path or reads a Core `.build` directory;
7. every profile selects exactly one application, platform, and transport, and
   claims the locked Core revision;
8. no literal Wi-Fi or broker credential is tracked;
9. every evidence record is well formed.

When an invariant changes, change the rule in the same commit. A rule that no
longer matches the invariant is worse than no rule.

## Working on an issue

1. Fetch and compare `origin/main` before branching.
2. Read the issue, and the authoritative upstream plan it names in
   `phynics/axoloty`. The upstream issue holds the acceptance criteria.
3. Branch per issue, one fix per branch.
4. Run `Tools/verify.sh` and keep it passing as you go, not at the end.
5. Record what you could not run, as an evidence record with status
   `unexecuted` and a reason. See [evidence.md](./evidence.md).
6. Commit with Conventional Commits and the configured identity. No bot
   co-author trailer.
7. Open the PR against `main` with `Closes #<issue-number>`.

## Scope discipline

Migration work is behavior-preserving. When you find an unrelated defect while
moving code, do not fix it in the migration change. Write it down, finish the
move, and file it separately. A migration diff that also fixes things cannot be
reviewed as a migration: nobody can tell which difference was deliberate.

## Composition

Firmware is `application x platform x transport`, selected by a profile. Each
axis has its own `AGENTS.md` stating what it may and may not contain. Read the
one for the directory you are editing.

```text
Applications/   what the firmware does
Platforms/      board, SDK, and toolchain integration
Transports/     embedded transport backends
Profiles/       a named application x platform x transport selection
```

A profile is declarative. It selects; it does not implement. If you are writing
logic inside `Profiles/`, it belongs in one of the other three.
