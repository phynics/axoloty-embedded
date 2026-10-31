# Wire parse time on ESP32-C6: `coaty/3` JSON and `axoloty/1` CBOR, 2026-10-31

Issue [#51](https://github.com/phynics/axoloty-embedded/issues/51), workstreams E0 and E1. Both images run the production `AxolotyWire` codec from Core `087bd9bb1bfb563d0347799245ea4dd43e509bc9` over the same 39 logical payloads (13 wire families, three size classes) in the smoke application's benchmark corpus. The JSON image times the payload text. The CBOR image times the deterministic `axoloty/1` encoding of the same payloads, generated at build time by `generate-embedded-corpus.mjs`.

## Result

Mean time per corpus case, in microseconds. Each figure is the median (p50) of 30 timed batches, so it describes a batch mean, not a per-message latency distribution.

| Step | JSON (`esp32c6-mqtt`) | CBOR (`esp32c6-zenoh`) | CBOR / JSON |
|---|---|---|---|
| Reader construction (tokenize or index) | 119.5 | 62.1 | 0.52 |
| DTO decode (reader plus DTO) | 144.5 | 93.4 | 0.65 |
| Decode then encode | 186.7 | 123.6 | 0.66 |

Derived by subtraction: the DTO step after the reader is about 25.0 µs for JSON and 31.3 µs for CBOR, and the encode step is about 42.1 µs for JSON and 30.1 µs for CBOR. The CBOR DTO step is slightly slower; the CBOR gain comes from indexing the payload faster. p95 is within 0.03% of p50 in every row, so the figures are stable on one board. Topic parse, combined and borrowed-message times were measured for JSON only (9.7, 167.0 and 10.3 µs). The CBOR image reports zero for them, which means unmeasured: the corpus topics are `coaty/3` routes.

## Method

- Both images were built from firmware revision `5ab8ce2bf42b1de9aa22dd75c936e8801ac8f46f` with a clean checkout and Core `087bd9bb…`, and flashed to the same board in the same session.
- MQTT image: 671,616 bytes, SHA-256 `b84716313be3288bbca86185e1d83a3ff1621cf79e92084eb93e6898ed12256f`. Zenoh image: 670,384 bytes, SHA-256 `1fbf87e605e3c7668256858d688d37b061cea6c1ce38bdf211376731720eff55`.
- Timing runs after 1,000 warm-up passes. The batch size doubles until a batch takes at least 250 ms, and the loop overhead is measured and subtracted.
- Before it times anything, the CBOR image decodes and re-encodes all 39 payloads. If one fails, every metric reports zero.
- The JSON image reproduced its 30 October figures to within 1 ns on a rebuilt image, so the benchmark is deterministic on this board.
- The corpus payloads are 8,568 bytes as JSON and 7,671 bytes as CBOR in total.

## Limits

- One board, one run per image. This is a measurement, not a guarantee, and it does not carry to other chips or clock settings.
- The corpus is the benchmark corpus, not live traffic. It has no object with a payload above 511 bytes.
- The CBOR payloads come from this repository's encoder, not from Core. Their validity rests on the on-device decode and re-encode check above, not on a byte comparison with Core.
- The images differ in transport as well as codec, so these figures isolate the codec but say nothing about flash or RAM from dropping JSON. That is E3.
- The completion records also show a main-stack remainder of 2,740 bytes on the MQTT image and 96,464 bytes on the Zenoh image. The images differ in transport and application work, so this note does not attribute the gap to the codec.
- The CBOR benchmark adds about 7.7 KB of `.bss` and about 15 KB of flash (hex text) to the Zenoh smoke image. The production budgets under #63 must not include this harness.
