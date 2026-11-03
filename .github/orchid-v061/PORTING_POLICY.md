# Orchid v0.6.1 — Pokopia integration baseline

The user's previous golden performance reference is retired. The source baseline for **all new binaries** is **MythosOfs/Orchid tag v0.6.1**, pinned to commit `8b4976375b066b4a2ea8ff6deb3f23c2409f1a82`. The old `ns2-pokopia-startup-fast-win32` and `ns2-pokopia-final-perf` branches remain historical references; never overwrite them.

## Current baseline gate

- Workflow: `.github/workflows/ns2-orchid-v061-zen4.yml`
- Checkout pinned upstream Orchid source directly, with **no inherited build142/build167/PokeDinner patch stack**.
- Compile with Orchid's **own v0.6.1 `eglantine.profdata` profile** and `-mtune=znver4`, then stage a portable Windows runtime and verify the package.
- Do not claim performance gain or runtime correctness from static source markers or successful compilation alone.
- Before *each* write, confirm the current `ns2-orchid-v061` HEAD. Keep changes narrow and idempotent.

## Confirmed already native in Orchid

| Feature | Baseline evidence | Decision |
| --- | --- | --- |
| GPU memory read traps and selective readback | `buffer_cache_base.h`: `ArmReadTraps`, `DownloadsAtFence`, `IsRegionPreflushable`, `FlushesOnCpuRead` | Keep Orchid. Do not reapply old QueueDownload/PR163 patches blindly. |
| Native pipeline reuse/translation | `renderer_vulkan/vk_pipeline_cache.cpp` has persistent cache and asynchronous native translation | Keep and benchmark. |
| Desktop draw batching threshold | `renderer_vulkan/vk_rasterizer.cpp` already defines `DRAWS_TO_DISPATCH = 4096` (desktop) | No port needed. |
| Native FSEL source modifiers and RET/link guards | `frontend/ampere/lower_to_maxwell.h` | Keep Orchid. |
| Switch 2 Pokopia Low GPU mapping correctness | Orchid v0.6.1 release, incorporating Eglantine build177 | Keep Orchid. |
| GPU thread command overhead and uniform-buffer reuse | Orchid v0.6.1 includes Eglantine build177 changes | Keep unless measured alternative is better. |
| Updated video/FSR/network/sparse-texture fixes | Orchid v0.6.1 release | Preserve upstream. |

## Candidate improvements — **not approved for unconditional port**

1. **Timing/HostMemory** — same Orchid build, same Pokopia scene/settings/cache with and without a narrowly scoped fallback. Preserve original behavior by default until evidence.
2. **Shader opcode `0x927` / Task/Mesh** — confirm exact native shader rejection and required semantics; port a **coherent** donor chain only if Orchid still lacks the mode. No partial translation or skipped essential draws.
3. **Startup/loose RomFS** — profile repeat and cold starts. Verify Orchid does not already cache the same work. Any new cache must keep invalidation and title/update semantics intact.
4. **Translation workers** — Orchid currently sizes translation workers as half its pipeline-worker count (minimum one). The older Pokopia branch favored **one** worker by default following visual problems with two. This is an A/B/correctness candidate, **not proof** the old behavior is better on Orchid.
5. **3 ms async wait policy** — inspect actual Orchid handoff logic and test against old policy. Do not introduce blocking into a working native path without measurements.
6. **Pipeline restoration** — preserve Orchid's existing cache; port only improvements demonstrated not already present.
7. **Build142 GPU-split/command-list copies** — isolated after correctness and translation gates; maintain writer-fence ordering.
8. **Submission/JIT/GPFIFO/scheduler/fastmem changes** — last priority, after above tests; never weaken safety checks.

## Gate for each subsequent port

Clean Orchid baseline compiled/packaged → identical-scene runtime A/B → demonstrate a missing mechanism and measurable benefit → narrow code patch with source-level correctness checks → compile/sanity test → full Zen4 PGO Windows package → artifact verification → fresh runtime A/B before accepting a behavioral change.

Avoid bulk transplantation of legacy compatibility scripts: their exact-text anchors repeatedly broke on upstream build167, and Orchid is newer still.
