# Build 142 selective runtime port

Donors from Djihads80/Eglantine:
- `46b2577bf78870ed85cbb790a9dc3c82cc77f4a7`: buffer binding guards.
- `a407703f6d29a5ab73328b4ededb12cf29b2758d`: ASTC submit policy, old-costly texture eviction, buffer address bounds.
- `8f1435f8db104351fa3388551eee9d12d2043b40`: command-list page copies.

Applied after the complete existing final stack, without changing its source base, Win32 RomFS enumeration, golden HostMemory toggle, shader cache format, or pipeline worker policy.

## Defaults and A/B controls

| Area | Default | Control |
|---|---|---|
| Invalid uniform/buffer addresses | Guarded | Always on |
| Empty stage updates | Skipped | Always on |
| ASTC completion | Submit without CPU wait | `EDEN_NX2_ASTC_FLUSH=0` restores blocking completion |
| Old costly textures under memory pressure | Eligible after 1800 frames | `EDEN_NX2_TC_OLD_AGE=0` disables the new eviction pass |
| Command-list page copies | Off pending gameplay validation | `EDEN_NX2_COMMAND_LIST_COPIES=1` enables |

Set environment variables before launching the executable. They are not qt-config.ini settings.

## Command-list adaptations

The port retains the existing exact-range, dirty-guarded flush as its fallback. It does not treat a partially flushed page as completely synchronized. Successful copies suppress older submission snapshots and cached guest-memory spans. Resumed command entries remain fresh reads.

Writer tracking covers scalar, multi-method, and the optimized Increasing-run parser. Graphics work is tracked too, conservatively waiting for a potential first draw write before accepting a copy. This may sacrifice some of the donor's overlap, but avoids relying on a page having already been observed as draw-written.

Copies require a completed GPU tick, matching write generation, covered byte range and stable GPU mapping generation. Host writes invalidate copies. Buffer deletion and GPU unmapping retire copies until the GPU completes them. At most 1024 command-list pages are retained; other pages use the original path. This is distinct from existing general buffer-download batching.

## Validation

The assembled source is checked with all existing core, PokeDinner, late, stability and legacy regression scripts, plus build142 source invariants. The patch supports a reverse applicability check to reject partial application. Windows C++ sanity covers startup, pipeline, Vulkan/OpenGL rasterizers, ASTC, DMA and split-thread translation units; the full Zen4 PGO workflow builds and packages the GUI.

No FPS gain is claimed without a same-save, same-settings Pokopia comparison. Compare cold/warm startup, a repeated heavy-scene route, frame-time spikes, visual correctness, and a longer session. Keep command-list copies off for the first baseline, then enable only that variable for the second run.
