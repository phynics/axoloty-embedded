# Resource budgets

A profile declares build-stage size budgets in its `profile.json`. The build
measures the linked image, writes `size.json` beside the artifact, and fails
when a metric exceeds its budget. The release manifest carries the report as
`resources`. This implements the build-stage part of
[#63](https://github.com/phynics/axoloty-embedded/issues/63).

## What is measured

`Platforms/esp32c6-idf/tools/write-size-report.mjs` reads the linked ELF with
the toolchain's `size -A`, and the image size from the `.bin`.

| Metric | Meaning |
|---|---|
| `imageBytes` | Size of `axoloty-swift.bin` |
| `flashTextBytes` | `.flash.text` |
| `flashRodataBytes` | `.flash.rodata` and `.flash.appdesc` |
| `iramTextBytes` | `.iram0.text` and its end marker |
| `initializedDataBytes` | `.iram0.data` and `.dram0.data` |
| `dramBssBytes` | `.dram0.bss` and `.noinit` |
| `staticRamBytes` | Instruction RAM, initialized data, and zeroed data together (the "static D/IRAM" figure) |

The padding section `.flash_rodata_dummy` is not flash use and is not counted.
The report also records the application partition size and the headroom left in
it, and names the profile, application, platform, transport, and Core revision
it was measured for. The Core revision comes from the preparation report, and
the image SHA-256 binds the measurement to the exact binary. A missing required
section, malformed table, or invalid budget declaration fails the report.
Optional end-marker, IRAM data, app descriptor, and no-init sections count as
zero when absent.

## What is budgeted

`profile.json` carries `budgets.build` for four metrics: `imageBytes`,
`flashTextBytes`, `staticRamBytes`, and `dramBssBytes`. `budgets.basis` states
what the numbers describe.

**Policy.** A budget is the measured value on the last certified image plus 10
percent, rounded up to the next KiB. The 10 percent leaves room for ordinary
change. A real regression, such as a linked-in dependency, exceeds it and fails
the build. When a budget is raised, the change records why.

**What the current numbers are.** The budgets in the two shipped profiles
describe the *smoke harness* images measured on `0.10.0-embedded.2` with Core
`v0.10.0`. They are regression gates for the harness and are not production
budgets: the smoke application carries test vectors and a benchmark corpus that
a production application would not. Production budgets belong to the production
reference application and its own profiles.

A numerical threshold does not transfer to another platform, Core revision, or
toolchain. Relocking Core or changing the SDK means measuring again and
resetting the budgets with new evidence.

## What is not covered

- **Configured qualification variants.** The C-only carrier scenario image is
  larger and is reported but not gated, following the static-storage policy
  receipt (`not-applicable`). This is a Zenoh qualification variant, not a
  qualified release artifact. A certificate for a qualified release cannot use
  the exemption; network-configured images are gated. Known limit: the
  validator cannot prove that a `not-applicable` report on an unqualified
  Zenoh manifest came from the C-only image. This does not affect certificates,
  because `--require-qualified` rejects the exemption.
- **Runtime budgets.** Minimum free heap and the main-stack remainder come from
  a device run and are not measured at build time. They are recorded in the smoke
  completion record and are not yet gated.
- **Stack bounds.** The report does not bound stack use.

## Releases must carry a report

A release of a profile that declares `budgets.build` must carry a size report in
`resources`; the validator rejects `resources: null` for it. Only the four
certificates issued before the report existed are exempt, through a fixed list of
exact `<profile>/<version>` entries in `Tools/validate-release-manifest.py`.

## Reading a report

`size.json` has `enforcement.status` of `passed`, `failed`, `not-applicable`
(a configured variant), or `not-configured` (the profile declares no budgets).
Only `passed`, `not-applicable`, and `not-configured` can appear in a
published certificate; the manifest validator rejects `failed`.
