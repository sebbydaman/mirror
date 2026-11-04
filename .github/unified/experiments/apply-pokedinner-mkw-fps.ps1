$ErrorActionPreference = 'Stop'
# Staged experiment; NOT part of the first unified PGO build.
# PokeDinner 2.5.0, Forgejo upstream 216b5034c60a, independently mirrored to GitHub:
# 969981/PokeDinner-a-Eglantine-Fork@16fa882b1be385f1475640550af451fff15c41f9.
# Port only Mario Kart World's opt-in 30 FPS and dynamic FPS modes; do not copy
# PokeDinner's DK 30 FPS patch (Orchid v0.7.0 already has a built-in one).
function Edit-Exact([string]$Path, [string]$Old, [string]$New, [string]$Name) {
    $text = [IO.File]::ReadAllText((Resolve-Path $Path).Path).Replace([string][char]13 + [string][char]10, [string][char]10)
    $oldNorm = $Old.Replace([string][char]13 + [string][char]10, [string][char]10).TrimEnd([char[]]@([char]13,[char]10))
    $newNorm = $New.Replace([string][char]13 + [string][char]10, [string][char]10).TrimEnd([char[]]@([char]13,[char]10))
    if ($text.Contains($newNorm)) { Write-Host "[ALREADY] $Name"; return }
    $at = $text.IndexOf($oldNorm, [StringComparison]::Ordinal)
    if ($at -lt 0 -or $text.IndexOf($oldNorm, $at + $oldNorm.Length, [StringComparison]::Ordinal) -ge 0) {
        throw "PokeDinner MKW optional port: missing/ambiguous Orchid anchor: $Name"
    }
    $text = $text.Substring(0,$at) + $newNorm + $text.Substring($at+$oldNorm.Length)
    [IO.File]::WriteAllText((Resolve-Path $Path).Path, $text, [Text.UTF8Encoding]::new($false))
    Write-Host "[PORTED] $Name"
}
$oldSettings = @'
    SwitchableSetting<bool> fps30_patch{linkage, false, "fps30_patch", Category::System};
'@
$newSettings = @'
    SwitchableSetting<bool> fps30_patch{linkage, false, "fps30_patch", Category::System};
    // PokeDinner 2.5.0: MKW-specific native frame-controller options. Both default OFF.
    SwitchableSetting<bool> mkw_30fps{linkage, false, "mkw_30fps", Category::RendererAdvanced};
    SwitchableSetting<bool> mkw_dynamic_fps{linkage, false, "mkw_dynamic_fps",
                                            Category::RendererAdvanced};
'@
Edit-Exact 'src/common/settings.h' $oldSettings $newSettings 'MKW opt-in settings'
$oldUi = @'
    INSERT(Settings, gpu_unswizzle_enabled, tr("GPU Unswizzle"),
'@
$newUi = @'
    INSERT(Settings, mkw_30fps, tr("Mario Kart World: native 30 FPS mode"),
           tr("Use the game's own 30 FPS mode at normal speed when it cannot hold 60. "
              "Requires a supported MKW binary; takes effect on next game start."));
    INSERT(Settings, mkw_dynamic_fps, tr("Mario Kart World: dynamic FPS (experimental)"),
           tr("The game dynamically chooses 1 or 2 vblanks from whole-frame time. "
              "Overrides MKW 30 FPS mode. Experimental and game-specific; "
              "takes effect on next game start."));
    INSERT(Settings, gpu_unswizzle_enabled, tr("GPU Unswizzle"),
'@
Edit-Exact 'src/qt_common/config/shared_translation.cpp' $oldUi $newUi 'MKW settings UI'
$oldCodeAnchor = @'
#ifdef HAS_NCE
    // If we are computing the process code layout and using nce backend, patch.
'@
$mkw = @'
    // Mario Kart World picks how many vblanks each frame lasts (its present interval) from a mode
    // in its frame loop: 0 = from the frame time, 1 = 60 fps, 2 = 30 fps, and advances its clock by
    // that many vblanks a frame. Forcing 2 gives a steady 30 fps at normal game speed. The mode's
    // load is found by its code (same in 1.0.0 at 0x3A9EC8 and 1.8.0 at 0x69CC54):
    //   cmp w9, w1; b.ne; ldr w8, [x19, #0x210]; cbnz w8; ... mov w8, #0x42700000 (60.0f)
    //
    // Dynamic mode (mkw_dynamic_fps) forces mode 0. The game then sets each frame's interval (1 or
    // 2 vblanks) from how late its frames run, but it times only its own CPU work ([fw+0x128],
    // calc), which is fast under emulation where the GPU thread is the slow part: it stayed at 1
    // and the game ran in slow motion. The same loop also stores the whole frame's time
    // ([fw+0xe8], calc + draw + present), so the interval code is pointed at that one.
    const bool mkw_dynamic = Settings::values.mkw_dynamic_fps.GetValue();
    if ((mkw_dynamic || Settings::values.mkw_30fps.GetValue()) && name == "main" &&
        process.GetProgramId() == 0x0400C3F00006E000ULL) {
        constexpr u32 ModeLoadInsn = 0xB9421268; // ldr w8, [x19, #0x210]
        const u32 Force30Insn = mkw_dynamic ? 0x52800008U  // mov w8, #0
                                            : 0x52800048U; // mov w8, #2
        const auto& text = nso_header.segments[0];
        u8* const code = codeset.memory.data() + module_start + text.location;
        const size_t count = text.size / sizeof(u32);
        const auto word = [code](size_t index) {
            u32 value;
            std::memcpy(&value, code + index * sizeof(u32), sizeof(value));
            return value;
        };
        size_t found = 0;
        size_t matches = 0;
        for (size_t i = 2; i + 8 < count; ++i) {
            if (word(i) != ModeLoadInsn || word(i - 2) != 0x6B01013F || // cmp w9, w1
                (word(i - 1) & 0xFF00001F) != 0x54000001 ||             // b.ne
                (word(i + 1) & 0xFF00001F) != 0x35000008) {             // cbnz w8
                continue;
            }
            for (size_t j = i + 2; j < i + 8; ++j) {
                if (word(j) == 0x52A84E08) { // mov w8, #0x42700000
                    found = i;
                    ++matches;
                    break;
                }
            }
        }
        // Dynamic: the frame time load after it, ldr xN, [x19, #0x128] -> [x19, #0xe8].
        size_t frame_time = 0;
        if (matches == 1 && mkw_dynamic) {
            for (size_t j = found + 1; j < found + 32 && j < count; ++j) {
                if ((word(j) & 0xFFFFFFE0) == 0xF9409660) {
                    frame_time = j;
                    break;
                }
            }
        }
        if (matches == 1 && mkw_dynamic && frame_time == 0) {
            LOG_WARNING(Loader, "Mario Kart World: dynamic FPS not applied (frame time not found)");
        } else if (matches == 1) {
            std::memcpy(code + found * sizeof(u32), &Force30Insn, sizeof(Force30Insn));
            if (mkw_dynamic) {
                const u32 whole_frame = 0xF9407660 | (word(frame_time) & 0x1F);
                std::memcpy(code + frame_time * sizeof(u32), &whole_frame, sizeof(whole_frame));
            }
            LOG_INFO(Loader, "Mario Kart World: {} on (main+{:#x})",
                     mkw_dynamic ? "dynamic FPS" : "30 FPS mode",
                     text.location + found * sizeof(u32));
        } else {
            LOG_WARNING(Loader, "Mario Kart World: 30 FPS mode not applied ({} matches)", matches);
        }
    }
'@
$newCodeAnchor = $mkw.TrimEnd([char[]]@([char]13,[char]10)) + [string][char]10 + [string][char]10 + $oldCodeAnchor.TrimEnd([char[]]@([char]13,[char]10))
Edit-Exact 'src/core/loader/nso.cpp' $oldCodeAnchor $newCodeAnchor 'MKW version-matched NSO frame-controller patch'
$oldTiming = @'
        const u32 requested_interval = std::clamp<u32>(timing >> 16, 1, 4);
        const u32 swap_interval = forced_interval != 0              ? forced_interval
                                  : m_swap_stable >= stable_presents ? requested_interval
                                                                     : 1;
'@
$newTiming = @'
        const u32 requested_interval = std::clamp<u32>(timing >> 16, 1, 4);
        // MKW dynamic mode must pace at each vblank so the game's own 1/2-vblank
        // controller can catch up. Keep explicit EDEN_NX2_SWAP_INTERVAL first and
        // retain Orchid's stable-present pacing for every other title.
        const bool mkw_dynamic = Settings::GetCurrentProgramID() == 0x0400C3F00006E000ULL &&
                                 Settings::values.mkw_dynamic_fps.GetValue();
        const u32 swap_interval = forced_interval != 0 ? forced_interval
                                : mkw_dynamic ? 1U
                                : m_swap_stable >= stable_presents ? requested_interval : 1U;
'@
Edit-Exact 'src/core/hle/service/nx2_gsv.h' $oldTiming $newTiming 'MKW dynamic frame present pacing'
foreach ($check in @(
    @('src/core/loader/nso.cpp', 'Mario Kart World: dynamic FPS not applied'),
    @('src/core/loader/nso.cpp', 'Mario Kart World: 30 FPS mode not applied'),
    @('src/core/hle/service/nx2_gsv.h', 'Settings::GetCurrentProgramID() == 0x0400C3F00006E000ULL'),
    @('src/common/settings.h', 'mkw_dynamic_fps'),
    @('src/qt_common/config/shared_translation.cpp', 'INSERT(Settings, mkw_30fps,'),
    @('src/common/settings.h', 'fps30_patch')
)) {
    if (-not (Select-String -Path $check[0] -SimpleMatch $check[1] -Quiet)) {
        throw "MKW optional donor invariant missing: $($check[1])"
    }
}
git diff --check
if ($LASTEXITCODE -ne 0) { throw 'MKW option patch introduced whitespace errors' }
Write-Host '[PASS] PokeDinner 2.5.0 optional MKW 30/dynamic FPS patch staged; unaffected games keep Orchid native pacing'
