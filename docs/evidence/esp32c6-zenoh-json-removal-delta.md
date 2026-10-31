# Cost of linking the JSON parser into the Zenoh smoke image, 2026-10-31

Issue [#51](https://github.com/phynics/axoloty-embedded/issues/51), workstream E3 and the memory half of E1. The question: what does the `esp32c6-zenoh` smoke image save by linking no JSON parser?

## Method

Two images from one firmware revision, `752168a4bc696f12897c886fba79d5e6d8aebf4a`, Core `087bd9bb1bfb563d0347799245ea4dd43e509bc9`, same transport, platform and board:

- **CBOR-only** (the shipped profile): `Transports/zenoh-pico/transport.json` declares `axoloty1CBOR`. SHA-256 `7c102f0c3180b67953d42c1188d50785c3440cb048bc791743d1d7f3c938b78b`.
- **JSON variant**: the same tree with that one field set to `coaty3JSON`, built in a throwaway clone that was never pushed. It links `_JSONCore` and runs the `coaty/3` smoke (v2). SHA-256 `2f21455f13c7139c93d520391d131dbf5350f9107778dc84cdec1f3628f4d4db`.

The variant is a measurement build only. It is not a supported profile, and it is not qualified. Both images were flashed to one board in one session, and both passed their smoke (CBOR 56/56, JSON 312/312, no failures).

## Result

| Measure | JSON variant | CBOR-only | Change |
|---|---|---|---|
| Image (`axoloty-swift.bin`) | 851,968 B | 670,464 B | −181,504 B (−21.3%) |
| `.flash.text` | 668,686 B | 494,936 B | −173,750 B (−26.0%) |
| `.flash.rodata` | 94,160 B | 86,864 B | −7,296 B |
| `.iram0.text` | 78,096 B | 78,092 B | −4 B |
| `.dram0.data` | 10,673 B | 10,209 B | −464 B |
| `.dram0.bss` | 63,704 B | 69,312 B | +5,608 B |
| Free internal heap at completion | 239,556 B | 234,420 B | −5,136 B |
| Minimum free internal heap | 237,500 B | 232,364 B | −5,136 B |
| Main stack remaining at its low point | 2,732 B | 96,464 B | +93,732 B |
| Hot-path allocations | 0 | 0 | none |

Both images fit the 2,031,616-byte application partition.

## Most of the flash saving is test code, not the library

These are Swift symbol sizes grouped by module, from `nm`. They sum to a smaller change than the section table (−168,696 B against −173,750 B) because alignment and unnamed symbols are not attributed.

| Module | JSON variant | CBOR-only | Change |
|---|---|---|---|
| `__idf_main` (the smoke application) | 244,440 B | 122,340 B | −122,100 B |
| `AxolotyObjectModel` | 24,748 B | 628 B | −24,120 B |
| `AxolotyWire` | 54,690 B | 31,852 B | −22,838 B |
| `_JSONCore` | 6,702 B | 0 B | −6,702 B |
| C and unmangled | 526,265 B | 522,247 B | −4,018 B |
| `AxolotyProtocol` | 38,726 B | 44,276 B | +5,550 B |
| `AxolotyStaticRuntime` | 0 B | 5,532 B | +5,532 B |

About 72% of the module-attributed drop is in the smoke application. The JSON image carries the `coaty/3` vectors and a 39-case corpus compiled into six timing passes. The CBOR image carries the smaller CBOR vector set and three passes. A production application would carry neither. The library modules together fall by about 53,700 B (`AxolotyObjectModel`, `AxolotyWire`, `_JSONCore`), and `AxolotyProtocol` and `AxolotyStaticRuntime` grow by about 11,100 B because the CBOR smoke exercises them. How much of the library change a production application would see depends on what it calls.

**The smoke images therefore overstate the saving.** A production figure needs the production reference application planned under #63.

## RAM

- **`.bss` rises on the CBOR image because of the benchmark, not the codec.** The CBOR corpus buffer is 7,671 B of `.bss`. The JSON image keeps its payloads in flash and uses a 2,056-byte parser workspace. Subtracting each harness item leaves 61,641 B (CBOR) and 61,648 B (JSON): the same to within 7 B. This rests on the assumption that those are the only harness differences in `.bss`.
- **The heap gap follows from the same buffer.** Free heap falls by 5,136 B, which matches the `.bss` and `.data` change (+5,144 B net). Without that buffer, the CBOR image would have about 2.5 KB more free heap than the JSON variant.
- **The stack figure is not a codec result.** The two images ran different smoke protocols (312 checks against 56), so their stack depth reflects different test code. The JSON image leaves 2,732 B of 131,072 B at its low point, and the CBOR image leaves 96,464 B. I did not isolate how much of that gap the codec causes.
- **The timing matches the MQTT run.** The JSON variant's reader time on Zenoh was 117.6 µs per case, against 119.5 µs on the MQTT image, so the codec cost does not depend on the transport. See [esp32c6-wire-parse-time.md](esp32c6-wire-parse-time.md).

## Limits

One board, one build per image, one revision. Section and symbol sizes are deterministic for a given build, but the runtime figures are single observations. The variant is not a supported configuration, and the throwaway clone is not retained. Re-create it by changing the one field named above.
