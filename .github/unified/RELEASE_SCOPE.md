# Orchid unified NX2 — integration scope and provenance

This build **is not a claim that every Eglantine, Lichii and PokeDinner patch was merged**. It is one Windows executable built from Orchid v0.7.0 plus small selected fixes verified against that exact source.

## Immutable source base

- `MythosOfs/Orchid`, tag `v0.7.0`: `d858fc90683ec55ecca9321081e719e02acbfd28`.
- The former Orchid v0.6.1 baseline was compiled and packaged successfully on run 41712670336. It remains an available fallback; this is an independent integration.
- Optimize for Windows x86_64, Ryzen Zen4 tuning (`-mtune=znver4`, not Zen4-only codegen), Clang PGO from Orchid's own `orchid.profdata`.

## Verified isolated ports selected for first integration

- **Eglantine build-212**: corrected native `H0_NH1` FP16 mixed-sign source, commit `77952c8d8c1bac5d6164587d69150c8ad0156ea0`.
- **Eglantine build-212**: treat a NUP package's contentless ExeFS as absent, `GetExeFSDir` part of `9279b24e4c487b75d1e8e88a1f99677512be1bab`. The separate NUP writer optimization is intentionally unported until tested.
- **Lichii build-70**: corrected blit-constant integer dither handling through float-derived Phi nodes for Kirby Air Riders, original commit `0aabd552a22d9d45612d4e828a667a808e36eed5`; limited to Switch 2 fragments and preserves Orchid's separate Fast Fusion HDR/tonemap bank-17 guard.
- **PokeDinner 2.5.0**: reviewed release `216b5034c6` and preserved compatible functionality already present in Orchid/upstream (e.g. NUP/NSP compatibility and DK lock support). No raw PokeDinner source patch was applied because this Forgejo snapshot has not yet been audited at the source level. The release's Splatoon Raiders visuals remain a candidate, not an asserted inclusion.

## Remaining high-value donor candidates, deliberately held back

| Donor | Candidate | Why not blanket-merged |
|---|---|---|
| Eglantine build-212 | Pokopia native ULEA/compute shader lowering, Fast Fusion shaders and GPU-split waits, Mario Tennis, NUP packer | Need validate against Orchid v0.7 current versions one group at a time |
| Lichii build-70 | Kirby dynamic texture arrays with separate samplers (#65), inline waited-on pipelines (#71), improved shader CFG (#71) | Shader cache versioning and threading semantics must be reviewed; no stage-specific regressions |
| Lichii build-70 | DKB GPU split synchronization (#70), Star Fox fixes, Sports Resort S16 sysmix (#75) | Significant shared GPU/audio interfaces; affected game smoke tests necessary |
| PokeDinner 2.5.0 | Splatoon Raiders visuals and any remaining unique Nintendo Switch 2 game-specific work | Exact tag source access/diff required; release notes alone do not prove safe code merge |
| All | Multiple overlapping 30 FPS/dynamic FPS options | Only one lock per game. Avoid applying duplicate patch engines or changing speed semantics |

## Preflight and acceptance

1. Pin and verify Orchid's exact SHA and `orchid.profdata`.
2. Apply small source ports with unique context anchors, rerun the script to prove idempotence, check git diff and preservation invariants.
3. Build C++ `shader_recompiler` and `core` targets; only then build full GUI.
4. Verify staged GUI, DLLs and Qt platform, build source/provenance, hash, artifact upload and packaging. **Compilation does not prove the fixes work in every game**.
5. Same-build/same-settings game-specific test before calling any FPS or visual improvement confirmed. Keep new game-specific optimizations off unless proven.

This branch is separate from `ns2-orchid-v061`, all golden/historical work, and Orchid upstream.
