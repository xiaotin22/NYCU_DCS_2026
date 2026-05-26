# ACT Five-Cycle Pipeline Design

## Scope

This design updates `ACT_TwoStage_Parallel` into a fixed-latency activation pipeline for the final CA RTL. The goal is to improve timing by spreading threshold computation and activation apply work across five cycles while preserving one matrix accepted per cycle.

The external datapath behavior should remain simple:

- Fixed ACT latency: 5 cycles.
- Initiation interval: 1 cycle.
- No new `in_ready` or stall signal.
- Existing 1024-bit signed 16-bit matrix input/output format is unchanged.

## Current Issue

The current two-stage ACT block processes 32 lanes per stage. For RAT, CAT, and BAT, each half-stage computes group sums, derives thresholds, and applies compare/mux logic in the same combinational path.

BAT is the heaviest case because a 4x4 block threshold needs 16 signed values summed before compare/mux activation. Keeping this in one stage can create a long critical path:

```text
sum tree -> threshold shift -> compare -> mux
```

## Proposed Architecture

Replace the two-stage ACT block with a fixed five-stage pipeline. Each matrix still enters on any cycle with `in_valid=1`, and its output appears five cycles later.

Each stage has two conceptual jobs:

```text
1. Compute one threshold chunk for the current matrix carried by that stage.
2. Apply the previous threshold chunk to 16 lanes of the same matrix.
```

The apply operation intentionally uses a threshold computed in the previous cycle. This avoids placing threshold sum and compare/mux for the same chunk in one combinational path.

## Stage Schedule

```text
Stage 0:
  - Capture matrix and control.
  - Compute threshold chunk 0.
  - No threshold apply yet.

Stage 1:
  - Compute threshold chunk 1.
  - Apply threshold chunk 0 to 16 lanes.

Stage 2:
  - Compute threshold chunk 2.
  - Apply threshold chunk 1 to 16 lanes.

Stage 3:
  - Compute threshold chunk 3.
  - Apply threshold chunk 2 to 16 lanes.

Stage 4:
  - Apply threshold chunk 3 to 16 lanes.
  - Register final output.
```

For ReLU and attention special activation, thresholds are not needed. These modes can use the same stage structure and apply their chunk-specific activation in stages 1 through 4. This keeps the output latency fixed at five cycles.

## Chunk Mapping

Each chunk covers 16 lanes.

RAT:

```text
chunk 0: rows 0 and 1
chunk 1: rows 2 and 3
chunk 2: rows 4 and 5
chunk 3: rows 6 and 7
```

CAT:

```text
chunk 0: columns 0 and 1
chunk 1: columns 2 and 3
chunk 2: columns 4 and 5
chunk 3: columns 6 and 7
```

BAT:

```text
chunk 0: upper-left  4x4 block
chunk 1: upper-right 4x4 block
chunk 2: lower-left  4x4 block
chunk 3: lower-right 4x4 block
```

ReLU:

```text
chunk 0..3: consecutive 16-lane groups, using value < 0 ? 0 : value
```

Attention special activation:

```text
chunk 0..3: consecutive 16-lane groups, using value < 0 ? value >>> 2 : value
```

## Data Carried Through Pipeline

Each stage should carry:

- Original source matrix, used for threshold computation.
- Partially activated result matrix.
- `act` and `act_mode` control.
- Threshold values already computed for chunks that still need apply.
- Valid bit.

The original source matrix must remain available for all threshold computations so earlier activation chunks do not affect later thresholds.

## Datapath Integration

The surrounding `CA_DataPath` currently assumes a two-cycle ACT latency and keeps `act_tag_q[0:1]` and `act_idx_q[0:1]`.

After this change, those metadata pipes must become five stages:

```text
act_tag_q[0:4]
act_idx_q[0:4]
```

All consumers of `act_tag_q[1]` and `act_idx_q[1]` should use stage 4 instead. This keeps ACT output data aligned with its pipeline tag and matrix index.

## Timing Expectations

The new critical paths should be shorter and more balanced:

- Threshold stages carry only one 16-lane chunk threshold computation.
- Apply stages carry only 16 independent compare/mux operations.
- Threshold computation and compare/mux for the same chunk are split across adjacent cycles.

The design should improve timing at the cost of three extra ACT latency cycles. Throughput remains unchanged because II stays at 1.

## Verification Checklist

Review the RTL by inspection for:

- `out_valid` delayed exactly five cycles from `in_valid`.
- `act_tag_q` and `act_idx_q` delayed exactly five cycles in `CA_DataPath`.
- ReLU, RAT, CAT, BAT, and attention special activation match the original formulas.
- RAT/CAT/BAT thresholds are computed from the original matrix, not the partially activated matrix.
- Signed arithmetic uses explicit signed types or casts where values are unpacked.
- Reset clears valid bits and externally visible outputs.
