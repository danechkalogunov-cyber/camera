# Review checklist — what the authors themselves are unsure about

Agents implementing this project are required to end with a list of what they could not verify.
That is more useful than confident silence, and this file is where those lists accumulate. Every
item here is a place a second reader should look, or a place where the first real camera will tell
us something.

Nothing in this file is a known defect. It is known *uncertainty*, which is different and more
actionable.

---

## VigilBitstream — H.265 (`impl:bitstream-b`)

The H.265 SPS parser is the highest-risk file in the pure layer: a mistake desynchronises the bit
reader and yields a plausible but wrong resolution rather than an error.

| Item | Risk if wrong | Status |
|---|---|---|
| **Inter-predicted short-term RPS chain** — three sets where set 1 predicts from set 0 and set 2 from set 1. The loop bound is `0...numDeltaPocs[refRpsIdx]`, **inclusive**, and the return is the count of contributing indices, not `NumDeltaPocs[RefRpsIdx]`. | Bit-reader desync → wrong resolution | Covered only by a **synthetic** vector the author wrote, validated against their own independent Python reference. No hardware capture exercises it. **Most worth a second reader.** |
| `delta_idx_minus1` when `stRpsIdx == num_short_term_ref_pic_sets` | none in practice | Unreachable from an SPS — it occurs only in the slice-header form. Implemented for correctness, dead, untested. |
| Sub-picture HRD (`sub_pic_hrd_params_present_flag`) | `minSpatialSegmentationIDC` falls back to 0 → one wrong byte in `hvcC`, **not** a black screen | Written from the spec, exercised by nothing. |
| 4:4:4 with `separate_colour_plane_flag`, and monochrome | wrong height derivation | Untested chroma paths. |
| `profile_tier_level` with more than two sub-layers | bit-reader desync | Only the single-sub-layer case is covered. |
| `default_display_window` parsed but deliberately **not applied** | a camera reporting the wrong display size | The decision is the specification's, not the implementer's. First place to look if display size is ever wrong. |

## Toolchain

- **swift-frontend 6.1.2 crashed (signal 4)** type-checking `Tests/VigilRTPTests/H264DepacketizerTests.swift`, blocking the shared test compile for about twenty minutes before clearing on the third attempt. Not our bug, but worth knowing: a compiler crash here looks exactly like a broken test file, and the response is to retry before rewriting anything.

## Cleanup owed

- Three files in `VigilBitstream` each carry an identical 15-line `fileprivate withNALPointer`
  bridge, because `withUnsafeBytes` is `rethrows` and erases a typed `BitstreamError` to
  `any Error`. The duplication was deliberate — the author would otherwise have had to claim a name
  in a module a sibling was writing concurrently — and should now be consolidated into one internal
  helper.

---

## How to use this file

Before the macOS layer is reviewed in step 4, every row here gets either a second reader or an
explicit "accepted, will find out on hardware". Items that survive to the first real camera test
become the first things checked when something looks wrong.
