$ErrorActionPreference = 'Stop'

# Reproduce the validated ebf4d44d runtime's Windows HostMemory fallback on demand without
# changing the default behavior. In the user's golden run, CreateFileMapping2 could not commit
# the 20 GiB Switch 2 backing store, so HostMemory fell back to a normal committed buffer and
# disabled the virtual fastmem arena. The startup-fast run had more swap available, the arena
# succeeded, and gameplay felt materially more sluggish despite similar/better present times.
#
# Set EDEN_NX2_FORCE_GOLDEN_HOSTMEM=1 before launching Eden to select the golden fallback path.
# Leave it unset for the normal fastmem path. This is intentionally a runtime A/B toggle.

$path = 'src/common/host_memory.cpp'
if (-not (Test-Path $path -PathType Leaf)) {
    throw "Golden HostMemory toggle: missing $path"
}

function Normalize([string]$text) {
    return $text.Replace("`r`n", "`n")
}

$text = Normalize (Get-Content $path -Raw)

if (-not $text.Contains('EDEN_NX2_FORCE_GOLDEN_HOSTMEM')) {
    if (-not $text.Contains('#include <cstdlib>')) {
        $includeAnchor = '#include <mutex>'
        if (-not $text.Contains($includeAnchor)) {
            throw 'Golden HostMemory toggle: <mutex> include anchor missing'
        }
        $text = $text.Replace($includeAnchor, "#include <cstdlib>`n$includeAnchor")
    }

    $old = @'
#else
    // Try to allocate a fastmem arena.
    impl = std::make_unique<HostMemory::Impl>(AlignUp(backing_size, PageAlignment), AlignUp(virtual_size, PageAlignment) + HugePageSize);
    if (impl->Init()) {
        backing_base = impl->backing_base;
        virtual_base = impl->virtual_base;
        if (virtual_base) {
            // Ensure the virtual base is aligned to the L2 block size.
            virtual_base = reinterpret_cast<u8*>(Common::AlignUp(uintptr_t(virtual_base), HugePageSize));
            virtual_base_offset = virtual_base - impl->virtual_base;
        }
    } else {
        LOG_WARNING(HW_Memory, "Platform can support fastmem, but can't create it");
        fallback_buffer = true;
        backing_base = static_cast<u8*>(impl->Allocate(backing_size));
        virtual_base = nullptr;
        impl.reset();
    }
#endif
'@

    $new = @'
#else
    // Try to allocate a fastmem arena. For controlled Pokopia A/B testing, allow reproducing the
    // exact Windows fallback path used by the validated ebf4d44d run without changing the default.
    impl = std::make_unique<HostMemory::Impl>(AlignUp(backing_size, PageAlignment), AlignUp(virtual_size, PageAlignment) + HugePageSize);

    bool force_golden_hostmem = false;
#ifdef _WIN32
    if (const char* value = std::getenv("EDEN_NX2_FORCE_GOLDEN_HOSTMEM"); value != nullptr) {
        force_golden_hostmem = value[0] == '1' && value[1] == '\0';
    }
#endif

    if (force_golden_hostmem) {
        LOG_WARNING(HW_Memory,
                    "EDEN_NX2_FORCE_GOLDEN_HOSTMEM=1: using ebf4d44d-style fallback HostMemory");
        fallback_buffer = true;
        backing_base = static_cast<u8*>(impl->Allocate(backing_size));
        ASSERT_MSG(backing_base != nullptr, "Failed to allocate forced golden HostMemory fallback");
        virtual_base = nullptr;
        impl.reset();
    } else if (impl->Init()) {
        backing_base = impl->backing_base;
        virtual_base = impl->virtual_base;
        if (virtual_base) {
            // Ensure the virtual base is aligned to the L2 block size.
            virtual_base = reinterpret_cast<u8*>(Common::AlignUp(uintptr_t(virtual_base), HugePageSize));
            virtual_base_offset = virtual_base - impl->virtual_base;
        }
    } else {
        LOG_WARNING(HW_Memory, "Platform can support fastmem, but can't create it");
        fallback_buffer = true;
        backing_base = static_cast<u8*>(impl->Allocate(backing_size));
        virtual_base = nullptr;
        impl.reset();
    }
#endif
'@

    if (-not $text.Contains((Normalize $old))) {
        throw 'Golden HostMemory toggle: HostMemory constructor anchor missing'
    }
    $text = $text.Replace((Normalize $old), (Normalize $new))
}

[IO.File]::WriteAllText((Resolve-Path $path).Path,
    $text.TrimEnd("`r", "`n") + "`n", [Text.UTF8Encoding]::new($false))

git diff --check -- $path
if ($LASTEXITCODE -ne 0) {
    throw 'Golden HostMemory toggle introduced diff/whitespace errors'
}

$verify = Normalize (Get-Content $path -Raw)
foreach ($needle in @(
    'EDEN_NX2_FORCE_GOLDEN_HOSTMEM',
    'force_golden_hostmem',
    'fallback_buffer = true;',
    'virtual_base = nullptr;'
)) {
    if (-not $verify.Contains($needle)) {
        throw "Golden HostMemory toggle verification failed: missing $needle"
    }
}

Write-Host '[APPLIED] Optional ebf4d44d-style Windows HostMemory fallback toggle'
Write-Host '          Set EDEN_NX2_FORCE_GOLDEN_HOSTMEM=1 before launch for the A/B test.'
