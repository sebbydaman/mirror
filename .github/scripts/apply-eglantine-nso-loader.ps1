$ErrorActionPreference = "Stop"

$path = "src/core/loader/nso.cpp"
$text = Get-Content $path -Raw

if ($text.Contains('NS2 robust NSO decompression')) {
    Write-Host "Robust NS2 NSO decompression is already present."
    exit 0
}

$needle = @'
            nso_file.Read(compressed_data.data(), nso_header.segments_compressed_size[i], nso_header.segments[i].offset);
            if (nso_header.IsSegmentCompressed(i)) {
                if (nso_header.IsZBICCompressed()) {
                    // ZBIC compression
                    const int r = Common::Compression::DecompressDataZBIC(
                        std::span<u8>{decompressed_size}.first(nso_header.segments[i].size),
                        std::span<const u8>{compressed_data}.first(nso_header.segments_compressed_size[i])
                    );
                    ASSERT(r > 0);
                } else {
                    // LZ4 compression
                    int r = Common::Compression::DecompressDataLZ4(
                        decompressed_size.data(),
                        nso_header.segments[i].size,
                        compressed_data.data(),
                        nso_header.segments_compressed_size[i]
                    );
                    ASSERT(r == int(nso_header.segments[i].size));
                }

                std::memcpy(
                    codeset.memory.data() + module_start + nso_header.segments[i].location,
                    decompressed_size.data(),
                    nso_header.segments[i].size
                );
            } else {
                // Not compressed
                std::memcpy(
                    codeset.memory.data() + module_start + nso_header.segments[i].location,
                    compressed_data.data(),
                    nso_header.segments[i].size
                );
            }
'@

if (-not $text.Contains($needle.TrimStart("`r", "`n"))) {
    throw "Could not locate Eglantine NSO decompression block"
}

$replacement = @'
            // NS2 robust NSO decompression: newer SDKs may use ZBIC even when the
            // legacy header flag is unreliable in extracted content. Detect the
            // stream magic, preserve LZ4 fallback, and retry the known 0x100/0x108
            // first-segment layout before accepting corrupted output.
            const size_t compressed_size = nso_header.segments_compressed_size[i];
            const size_t expected_size = nso_header.segments[i].size;
            const size_t primary_offset = nso_header.segments[i].offset;

            auto read_compressed = [&](size_t file_offset) -> bool {
                if (nso_file.Read(compressed_data.data(), compressed_size, file_offset) != compressed_size) {
                    LOG_ERROR(Loader, "Failed to read NSO segment {} at offset {:#x}", i, file_offset);
                    return false;
                }
                return true;
            };

            auto decompress_at = [&](size_t file_offset) -> int {
                if (!read_compressed(file_offset)) {
                    return -1;
                }
                auto dst = std::span<u8>{decompressed_size}.first(expected_size);
                auto src = std::span<const u8>{compressed_data}.first(compressed_size);
                const bool prefer_zbic = nso_header.IsZBICCompressed() || Common::Compression::IsZBIC(src);

                if (prefer_zbic) {
                    const int zbic_result = Common::Compression::DecompressDataZBIC(dst, src);
                    if (zbic_result == static_cast<int>(expected_size)) {
                        return zbic_result;
                    }
                }

                const int lz4_result = Common::Compression::DecompressDataLZ4(
                    dst.data(), dst.size(), src.data(), src.size());
                if (lz4_result == static_cast<int>(expected_size)) {
                    return lz4_result;
                }

                // Some extracted NSOs have been observed without a trustworthy bit-7
                // indication. A failed LZ4 decode is cheap enough to verify against ZBIC.
                if (!prefer_zbic) {
                    return Common::Compression::DecompressDataZBIC(dst, src);
                }
                return lz4_result;
            };

            if (nso_header.IsSegmentCompressed(i)) {
                int result = decompress_at(primary_offset);
                if (result != static_cast<int>(expected_size) && i == 0 &&
                    primary_offset == sizeof(NSOHeader)) {
                    constexpr size_t AlternateFirstSegmentOffset = sizeof(NSOHeader) + 8;
                    result = decompress_at(AlternateFirstSegmentOffset);
                    if (result == static_cast<int>(expected_size)) {
                        LOG_INFO(Loader, "Recovered NSO segment 0 using alternate offset {:#x}",
                                 AlternateFirstSegmentOffset);
                    }
                }
                if (result != static_cast<int>(expected_size)) {
                    LOG_ERROR(Loader,
                              "NSO segment {} decompression failed: expected {:#x} bytes, got {}",
                              i, expected_size, result);
                    return std::nullopt;
                }

                std::memcpy(
                    codeset.memory.data() + module_start + nso_header.segments[i].location,
                    decompressed_size.data(), expected_size);
            } else {
                // Uncompressed segments should be copied directly from their file range.
                if (nso_file.Read(
                        codeset.memory.data() + module_start + nso_header.segments[i].location,
                        expected_size, primary_offset) != expected_size) {
                    LOG_ERROR(Loader, "Failed to read uncompressed NSO segment {}", i);
                    return std::nullopt;
                }
            }
'@

$text = $text.Replace($needle.TrimStart("`r", "`n"), $replacement.TrimStart("`r", "`n"))
Set-Content -Path $path -Value $text -Encoding utf8 -NoNewline

if (-not $text.Contains('Common::Compression::IsZBIC(src)')) {
    throw "NS2 ZBIC magic detection was not applied"
}
if (-not $text.Contains('AlternateFirstSegmentOffset')) {
    throw "NS2 alternate first-segment offset fallback was not applied"
}
if (-not $text.Contains('NSO segment {} decompression failed')) {
    throw "NS2 decompression failure guard was not applied"
}

Write-Host "Enabled robust NS2 NSO decompression with ZBIC magic detection, LZ4 fallback and alternate-offset recovery."
git diff -- $path
