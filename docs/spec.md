# Rules and their sources

The judge, gauge and chart behaviour are ports of lr2oraja's code, which is GPLv3. OpenLR2 is not used, because it
derives from decompilation. "LR2 rule" below means lr2oraja's implementation of it, not a measurement of LR2 itself.

| Item | Rule | Source | Our code |
| --- | --- | --- | --- |
| Judge windows | PG 21, GR 60, GD 120, BD 200 ms; POOR 0 to 1000 ms early. LN end GD 120, BD 200 | `JudgeProperty.LR2`, `JudgeWindowRule.createLR2` | `src/core/windows.zig` |
| #RANK scaling | Piecewise table by rank; `judgerank` ≥ 100 scales linearly | same | `src/core/windows.zig` |
| Gauges | Nine types, f32 on purpose so accumulated rounding matches | `GaugeProperty.LR2`, `GrooveGauge` | `src/core/gauge.zig` |
| Judge flow | Combo table, empty POOR, multi-BAD filter, LN and CN and HCN handling | `JudgeManager`, `JudgeAlgorithm` | `src/core/sim.zig` |
| Chart hash | MD5 and SHA-256 of the raw file bytes | jbms-parser `BMSDecoder` | `src/bms/hash.zig` |
| Chart parsing | Timelines, #RANDOM, #LNOBJ, #LNTYPE, measure scale, BMSON | jbms-parser `BMSDecoder`, `BMSONDecoder` | `src/bms/parser.zig`, `src/bms/bmson.zig` |
| Difficulty tables | HTML `bmstable` meta to header JSON to data JSON, courses from the header | bmstable format, lr2oraja `TableDataAccessor` | `src/table/table.zig` |

## Determinism

The simulation never reads a clock. It takes timestamped input and steps on an absolute 1 ms grid, so frame rate cannot
change a result. A replay is the input stream, and the IR server re-simulates it with this same code through a C ABI.

## Intentional differences from beatoraja

beatoraja's parser ignores two commands that the BMS format defines and that we implement:

- `#ELSE` and `#ELSEIF`: beatoraja keeps both branches.
- `#SWITCH`, `#CASE`, `#SKIP`, `#DEF`: beatoraja treats them as unknown and keeps every branch.

Such charts have the same hashes as in beatoraja, but can have different notes, so a score may not be comparable.
`tests/charts/random_nested.bms` and `switch.bms` pin our behaviour; their golden lines were checked by hand, not from
the jar.

## Parity evidence

Fingerprints are note time, lane, kind and keysound, plus hashes, mode and length, from
`tools/golden/DumpChart.java` run against the installed lr2oraja jar. `tools/chartdump.zig` prints the same line.

| Set | Result |
| --- | --- |
| 57 real charts | all match |
| 3000 mutated charts (`tools/golden/mutate.py`) | 26 differ (0.9%): same-time collisions with tiny rates, unterminated LN, 1 µs float rounding |
| `tests/charts`, 16 edge cases | 14 match the jar, 2 are the intentional differences above. Runs in CI from the stored `golden.tsv` |
| Parser fuzz, ReleaseSafe | 3000 iterations over the real charts: no crash, no leak |

The jar predates current jbms-parser master, so `#LNMODE`, `#BASE 62` and negative `#xxx02` are excluded from the mutation
run and are compared against reading the source only.

## Known gaps in the evidence

- The plan calls for thousands of charts in the golden set. It has 57 real ones.
- The judge has not been compared against real LR2 replays, or run differentially against lr2oraja's `JudgeManager`.
  Its port is checked by unit tests and by the replay round trip through the IR server.
- Beatoraja score import was checked against the real schema only. LR2 import was checked against a test-made database.

## Latency measured on the development machine

`actuon latency`, Linux: queue to judge p50 0.304, p99 0.344, max 0.543 ms. Audio loopback needs a physical cable to
mean anything and has not been measured with one. Windows and macOS are not measured.
