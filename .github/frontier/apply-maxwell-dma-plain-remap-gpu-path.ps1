$ErrorActionPreference = 'Stop'

# Citron 84cdb4c: the accelerated block-linear<->pitch paths take widths/origins in bytes. With
# REMAP_ENABLE the Maxwell DMA registers describe elements instead. When the remap is a true plain
# copy (same source/destination component count and DST_i == SRC_i), scale the existing GPU-path
# parameters by source element size and keep the transfer on the GPU. Complex remaps remain on the
# existing CPU/swizzle fallback. This ports only the isolated plain-copy gate, not Citron's broader
# remap implementation.

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
    [IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, [Text.UTF8Encoding]::new($false))
}

function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Name) {
    $Text = $Text.Replace("`r`n", "`n")
    $Old = $Old.Replace("`r`n", "`n")
    $New = $New.Replace("`r`n", "`n")
    $first = $Text.IndexOf($Old, [StringComparison]::Ordinal)
    if ($first -lt 0) { throw "Maxwell DMA plain-remap GPU path: missing anchor $Name" }
    if ($Text.IndexOf($Old, $first + $Old.Length, [StringComparison]::Ordinal) -ge 0) {
        throw "Maxwell DMA plain-remap GPU path: ambiguous anchor $Name"
    }
    return $Text.Substring(0, $first) + $New + $Text.Substring($first + $Old.Length)
}

$headerPath = 'src/video_core/engines/maxwell_dma.h'
$cppPath = 'src/video_core/engines/maxwell_dma.cpp'
foreach ($path in @($headerPath, $cppPath)) {
    if (-not (Test-Path $path -PathType Leaf)) {
        throw "Maxwell DMA plain-remap GPU path: missing $path"
    }
}

$header = (Get-Content $headerPath -Raw).Replace("`r`n", "`n")
if (-not $header.Contains('bool IsPlainCopy() const;')) {
    $oldUnion = @'
        union {
            BitField<0, 12, u32> dst_components_raw;
            BitField<0, 3, Swizzle> dst_x;
            BitField<4, 3, Swizzle> dst_y;
            BitField<8, 3, Swizzle> dst_z;
            BitField<12, 3, Swizzle> dst_w;
            BitField<16, 2, u32> component_size_minus_one;
            BitField<20, 2, u32> num_src_components_minus_one;
            BitField<24, 2, u32> num_dst_components_minus_one;
        };

        Swizzle GetComponent(size_t i) const {
            const u32 raw = dst_components_raw;
            return static_cast<Swizzle>((raw >> (i * 3)) & 0x7);
        }
'@
    $newUnion = @'
        union {
            u32 components_raw;
            BitField<0, 12, u32> dst_components_raw;
            BitField<0, 3, Swizzle> dst_x;
            BitField<4, 3, Swizzle> dst_y;
            BitField<8, 3, Swizzle> dst_z;
            BitField<12, 3, Swizzle> dst_w;
            BitField<16, 2, u32> component_size_minus_one;
            BitField<20, 2, u32> num_src_components_minus_one;
            BitField<24, 2, u32> num_dst_components_minus_one;
        };

        Swizzle GetComponent(size_t i) const {
            const u32 raw = dst_components_raw;
            return static_cast<Swizzle>((raw >> (i * 3)) & 0x7);
        }

        /// SET_REMAP_COMPONENTS encodes destination selectors at bits 0,4,8,12.
        [[nodiscard]] Swizzle DstComponent(u32 i) const {
            return static_cast<Swizzle>((components_raw >> (i * 4)) & 0x7);
        }
        [[nodiscard]] u32 ComponentSize() const {
            return component_size_minus_one + 1;
        }
        [[nodiscard]] u32 SrcElementSize() const {
            return (num_src_components_minus_one + 1) * ComponentSize();
        }
        /// True when the remap leaves every destination component equal to its matching source.
        [[nodiscard]] bool IsPlainCopy() const;
'@
    $header = Replace-Once $header $oldUnion.TrimEnd("`r", "`n") $newUnion.TrimEnd("`r", "`n") `
        'RemapConst plain-copy helpers'

    $oldDecl = @'
    void CopyBlockLinearToPitch();

    void CopyPitchToBlockLinear();
'@
    $newDecl = @'
    void CopyBlockLinearToPitch();

    /// Convert element-based remapped image/buffer copy parameters to the byte units consumed by
    /// the accelerated GPU path. Returns false for any remap that changes component contents.
    [[nodiscard]] bool ScaleForPlainCopy(DMA::Parameters& image_params,
                                         DMA::ImageCopy& copy_info, u32& buffer_width) const;

    void CopyPitchToBlockLinear();
'@
    $header = Replace-Once $header $oldDecl.TrimEnd("`r", "`n") $newDecl.TrimEnd("`r", "`n") `
        'ScaleForPlainCopy declaration'
    Write-PatchedText $headerPath $header
}

$cpp = (Get-Content $cppPath -Raw).Replace("`r`n", "`n")
if (-not $cpp.Contains('bool MaxwellDMA::RemapConst::IsPlainCopy() const')) {
    $functionAnchor = 'void MaxwellDMA::CopyBlockLinearToPitch() {'
    $insert = @'
bool MaxwellDMA::RemapConst::IsPlainCopy() const {
    const u32 num_dst = num_dst_components_minus_one + 1;
    if (num_src_components_minus_one + 1 != num_dst) {
        return false;
    }
    for (u32 i = 0; i < num_dst; ++i) {
        if (DstComponent(i) != static_cast<Swizzle>(i)) {
            return false;
        }
    }
    return true;
}

bool MaxwellDMA::ScaleForPlainCopy(DMA::Parameters& image_params, DMA::ImageCopy& copy_info,
                                   u32& buffer_width) const {
    if (regs.launch_dma.remap_enable == 0) {
        return true;
    }
    if (!regs.remap_const.IsPlainCopy()) {
        return false;
    }
    const u32 element_size = regs.remap_const.SrcElementSize();
    const u32 origin_x = image_params.origin.x.Value() * element_size;
    if (origin_x > 0xFFFF) {
        return false;
    }
    image_params.width *= element_size;
    image_params.origin.x.Assign(origin_x);
    copy_info.length_x *= element_size;
    buffer_width *= element_size;
    return true;
}

'@
    $idx = $cpp.IndexOf($functionAnchor, [StringComparison]::Ordinal)
    if ($idx -lt 0) { throw 'Maxwell DMA plain-remap GPU path: CopyBlockLinearToPitch anchor missing' }
    $cpp = $cpp.Insert($idx, $insert.Replace("`r`n", "`n"))
}

if (-not $cpp.Contains('ScaleForPlainCopy(src_operand.params, copy_info, dst_operand.width)')) {
    $cpp = Replace-Once $cpp `
        '    if (accelerate.ImageToBuffer(copy_info, src_operand, dst_operand)) {' `
        "    if (ScaleForPlainCopy(src_operand.params, copy_info, dst_operand.width) &&`n        accelerate.ImageToBuffer(copy_info, src_operand, dst_operand)) {" `
        'block-linear to pitch accelerated copy gate'
}
if (-not $cpp.Contains('ScaleForPlainCopy(dst_operand.params, copy_info, src_operand.width)')) {
    $cpp = Replace-Once $cpp `
        '    if (accelerate.BufferToImage(copy_info, src_operand, dst_operand)) {' `
        "    if (ScaleForPlainCopy(dst_operand.params, copy_info, src_operand.width) &&`n        accelerate.BufferToImage(copy_info, src_operand, dst_operand)) {" `
        'pitch to block-linear accelerated copy gate'
}
Write-PatchedText $cppPath $cpp

$headerFinal = Get-Content $headerPath -Raw
$cppFinal = Get-Content $cppPath -Raw
foreach ($needle in @(
    'u32 components_raw;',
    'components_raw >> (i * 4)',
    'u32 SrcElementSize() const',
    'bool IsPlainCopy() const;',
    'bool ScaleForPlainCopy(DMA::Parameters& image_params,'
)) {
    if (-not $headerFinal.Contains($needle)) {
        throw "Maxwell DMA plain-remap GPU path validation failed: header missing $needle"
    }
}
foreach ($needle in @(
    'bool MaxwellDMA::RemapConst::IsPlainCopy() const',
    'if (!regs.remap_const.IsPlainCopy())',
    'image_params.origin.x.Assign(origin_x);',
    'ScaleForPlainCopy(src_operand.params, copy_info, dst_operand.width)',
    'ScaleForPlainCopy(dst_operand.params, copy_info, src_operand.width)'
)) {
    if (-not $cppFinal.Contains($needle)) {
        throw "Maxwell DMA plain-remap GPU path validation failed: source missing $needle"
    }
}

& git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'Maxwell DMA plain-remap GPU path introduced diff/whitespace errors'
}
Write-Host 'Maxwell DMA plain-remap GPU path validated: plain remaps use byte-scaled accelerated copies; complex remaps retain CPU fallback.'
