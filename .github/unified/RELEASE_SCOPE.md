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
- **PokeDinner 2.5.0**: release `216b5034c6` maps to the independent GitHub Forgejo source sync `969981/PokeDinner-a-Eglantine-Fork@16fa882b1be385f1475640550af451fff15c41f9` (commit message: sync Forgejo master `216b5034c60a`). This gives a citable source snapshot for targeted comparisons. No PokeDinner source patch is applied in this first batch; inspect its unique MKW Dynamic FPS mode and any Splatoon visuals individually. Orchid already implements NUP/NSP compatibility and DK built-in 30 FPS lock.

## Remaining high-value donor candidates, deliberately held back

| Donor | Candidate | Why not blanket-merged |
|---|---|---|
| Eglantine build-212 | Pokopia native ULEA/compute shader lowering, Fast Fusion shaders and GPU-split waits, Mario Tennis, NUP packer | Need validate against Orchid v0.7 current versions one group at a time |
| Lichii build-70 | Kirby dynamic texture arrays with separate samplers (#65), inline waited-on pipelines (#71) | Shader cache versioning and threading semantics must be reviewed; no stage-specific regressions. Lichii's faster control-flow traversal (#71) is already present in Orchid v0.7.0; do not duplicate. |
| Lichii build-70 | DKB GPU split synchronization (#70), Star Fox fixes, Sports Resort S16 sysmix (#75) | Significant shared GPU/audio interfaces; affected game smoke tests necessary |
| PokeDinner 2.5.0 | Mario Kart World optional 30 FPS/dynamic FPS, Splatoon Raiders visuals | Forgejo source snapshot mirrored at `969981/PokeDinner-a-Eglantine-Fork@16fa882`; review its `src/core/loader/nso.cpp`, `src/common/settings.h`, `src/core/hle/service/nx2_gsv.h`, and renderer against newer Orchid before porting. Unique MKW dynamic FPS is not in Orchid; Orchid already has a generic DK 30 FPS patch. |
| All | Multiple overlapping 30 FPS/dynamic FPS options | Only one lock per game. Avoid applying duplicate patch engines or changing speed semantics |

## PokeDinner 2.5.0 verified source inventory

An independently accessible GitHub mirror contains a full checkout of Forgejo master at 2.5.0. The sync commit `16fa882b1be385f1475640550af451fff15c41f9` explicitly records upstream `216b5034c60a`; avoid newer mirror-only CI commits when attributing game code.

Its release contains an optional Mario Kart World frame-controller code patch in `src/core/loader/nso.cpp` with match-count guards (30 FPS mode or a dynamic FPS variant), a present-pacing adjustment in `src/core/hle/service/nx2_gsv.h`, plus matching UI settings. Orchid v0.7.0 lacks this exact MKW mode but contains its own configurable Donkey Kong Bananza 30 FPS patch. Do **not** transplant PokeDinner's separate DK patch over Orchid's generic one. Keep MKW dynamic FPS and its frame-pacing changes as a grouped, opt-in, version-matched experiment. It has no demonstrated FPS benefit in Orchid and must be tested independently from other game fixes.

A source-tree inventory found approximately **402 differing common blob paths** between the PokeDinner snapshot and Orchid v0.7.0. Most differences cannot be treated as additive fixes; both projects have had significant independent GPU/video evolution. Source-level diffs and game reproduction are mandatory.

## Missing shader instruction coverage

Comparing the actual `src/shader_recompiler/frontend/ampere/lower_to_maxwell.h` switch cases at the three pinned source revisions found **15 Eglantine build-212 and 21 Lichii build-70 case opcodes not represented as cases in Orchid v0.7.0**. This is a syntactic case audit, **not** proof each is unsupported at runtime.

In particular, opcode `0x927` (task/mesh `ISBEWR`) is absent from Orchid's *active* lowering switch, although an unused `lower_to_maxwell_upstream.h` reference does contain `case 0x923: case 0x927`. Active Orchid already treats `0x923` as a geometry/tessellation read; importing the donor's combined case wholesale would replace newer behavior. Review and port an entire coherent task/mesh lowering chain only after a dedicated shader semantic gate, then a C++ and full Windows build. Do not just copy the single switch case.

The donor's newer NUP writer optimization and Eglantine's remaining Pokopia/Star Fox/Fast Fusion shaders are also pending independent source-level correctness gates.

## Staged but not yet compiled second-phase candidates

These files are deliberately **not called by the initial unified workflow**; they need their own independent cheap C++ and game-correctness gates after the initial artifact has compiled and packaged:

- `.github/unified/experiments/apply-native-taskmesh-stage-buffer.ps1`: a source-anchor-checked native `0x923/0x927` Task/Mesh read/write lowering candidate based on Eglantine build212 and Orchid's own unused upstream donor. Keeps active Orchid geometry/tessellation read instructions intact. A script-level check verifies `ISBE_nx2` backend availability. Targeted shader compilation and native game testing still outstanding.
- `.github/unified/experiments/apply-pokedinner-mkw-fps.ps1`: PokeDinner 2.5.0 code-matched optional MKW 30 FPS and dynamic FPS modes. Four exact Orchid v0.7.0 source anchors verified present uniquely; defaults OFF, has a title-ID guard on presentation changes, retains Orchid's built-in DK 30 FPS code and `EDEN_NX2_SWAP_STABLE` policy for other titles. Targeted C++ compile and an affected-game test still outstanding.
- `.github/unified/experiments/apply-lichii-streamplay-hid.ps1`: Lichii build70 PR #64's Star Fox/GameShare HID command-300 IPC contract. Replaces the guessed event response on both user and NGC shim service routes with a zero-initialized `0x9b000` shared-memory object and the required size/offset reply. The original Orchid v0.7.0 entry points are uniquely matched; the helper and changed service routes are staged for focused C++ compilation and IPC/game testing. Not included in first production package.
- Lichii build70 dynamic texture arrays, waited-on pipeline scheduling, and back-thread synchronization have not yet been ported: preserve shader-cache and scheduler ownership guarantees.

All staged candidates need clean builds and runtime A/B before promotion. No claim of working compatibility or FPS gains for them is supported yet.

**Independent Windows C++ candidate gate:** [Actions run #41878900706](https://github.com/sebbydaman/mirror/actions/runs/41878900706) builds `shader_recompiler` after Task/Mesh, `core` after MKW, and `core` again after the Lichii HID addition. It is distinct from the successful baseline C++/GUI compile in the first unified Windows PGO run [#41868882990](https://github.com/sebbydaman/mirror/actions/runs/41868882990); final portable-package verification is separately gated.

## Independent donor compilation and pipeline stalls

The first two Orchid v0.7.0 Windows PGO builds passed source, targeted C++, full GUI, staging and portable package verification: [#41868882990](https://github.com/sebbydaman/mirror/actions/runs/41868882990) and [#41868983830](https://github.com/sebbydaman/mirror/actions/runs/41868983830). These are **compile and package successes**, not in-game FPS benchmarks.

The first donor workflow failed before compilation because the Task/Mesh script's multiline PowerShell match preserved Windows CRLF line endings while the target source was normalized to LF. Diagnostic run [#41890396929](https://github.com/sebbydaman/mirror/actions/runs/41890396929) confirmed `fullMatch=-1, caseAt=146770, anchorLength=525`. The exact matcher has been corrected to normalize CRLF on both old and new snippets; no opcode safety predicates were removed.

An independent four-candidate Windows gate [#41891471057](https://github.com/sebbydaman/mirror/actions/runs/41891471057) now tests Task/Mesh, PokeDinner MKW dynamic/30, Lichii Star Fox HID, and Lichii waited-on Vulkan pipeline compilation. It avoids a failing Task/Mesh source step from skipping other game builds.

The fourth staged donor, `.github/unified/experiments/apply-lichii-inline-pipeline-builds.ps1`, ports the Lichii build-70 PR #71 `457a32de0a` approach into a *separate candidate*: when a draw needs a pipeline, its scheduler may claim and compile it immediately instead of waiting behind hundreds of background worker compiles. The design keeps one build owner via `build_claimed` and retains the completion condition variable. The source anchors are checked against pinned Orchid v0.7.0. This is a promising shader-stall optimization but should remain isolated until Vulkan `video_core` compiles, gameplay stability is checked, and an A/B measurement demonstrates benefit.

## Fast source validation — November 4, 2026

The new Windows [fast four-candidate source gate #41893968205](https://github.com/sebbydaman/mirror/actions/runs/41893968205) **passed all four matrices** (Task/Mesh, Mario Kart World, Star Fox, and waited-on Vulkan pipelines). Each applies the previously compiled unified ports, applies its isolated donor patch twice, checks that the source diff is idempotent, and checks `git diff --check`. It does not compile the C++ or run a game.

This resolves the prior Task/Mesh source-anchor failure with an actual GitHub Actions result, not only local string comparison. The expensive independent Windows C++ checks remain outstanding.

Lichii build70 Kirby dynamic texture-array port (#65) is not a single small change: commits `d5ed8e1a97c85f57f795486d4961ef94466365af` and `f2cd29272e8b75e7be8860ec181cc342332dd760` alter texture handle reconstruction, Vulkan/OpenGL combined sampler bindings, descriptor-array limit accounting, and shader cache versioning. **Orchid v0.7.0 no longer has Lichii's `src/video_core/pipeline_cache_files.h` file**, so a blind transplant of cache-version changes is unsafe. Hold the port until Orchid's newer shader-cache architecture is mapped and tested.

## Preflight and acceptance

1. Pin and verify Orchid's exact SHA and `orchid.profdata`.
2. Apply small source ports with unique context anchors, rerun the script to prove idempotence, check git diff and preservation invariants.
3. Build C++ `shader_recompiler` and `core` targets; only then build full GUI.
4. Verify staged GUI, DLLs and Qt platform, build source/provenance, hash, artifact upload and packaging. **Compilation does not prove the fixes work in every game**.
5. Same-build/same-settings game-specific test before calling any FPS or visual improvement confirmed. Keep new game-specific optimizations off unless proven.

This branch is separate from `ns2-orchid-v061`, all golden/historical work, and Orchid upstream.
