$ErrorActionPreference = 'Stop'
# Staged Lichii build70 PR #64 Star Fox guest HID IPC fix. NOT part of initial packaged build.
# Source: zortos293/Lichii@286117c7e0d89ab0384e896489128fdd88a424f8
# Both streamplay command-300 routes return the shared-memory handle plus size/offset.
function Replace-Unique([string]$Path, [string]$Old, [string]$New, [string]$Name) {
    $text = [IO.File]::ReadAllText((Resolve-Path $Path).Path).Replace([string][char]13 + [string][char]10, [string][char]10)
    $oldNorm = $Old.Replace([string][char]13 + [string][char]10, [string][char]10).TrimEnd([char[]]@([char]13,[char]10))
    $newNorm = $New.Replace([string][char]13 + [string][char]10, [string][char]10).TrimEnd([char[]]@([char]13,[char]10))
    if ($text.Contains($newNorm)) { Write-Host "[ALREADY] $Name"; return }
    $idx = $text.IndexOf($oldNorm, [StringComparison]::Ordinal)
    if ($idx -lt 0 -or $text.IndexOf($oldNorm, $idx+$oldNorm.Length, [StringComparison]::Ordinal) -ge 0) {
        throw "Lichii streamplay HID source anchor missing/ambiguous: $Name"
    }
    $updated = $text.Substring(0,$idx) + $newNorm + $text.Substring($idx+$oldNorm.Length)
    [IO.File]::WriteAllText((Resolve-Path $Path).Path,$updated,[Text.UTF8Encoding]::new($false))
    Write-Host "[PORTED] $Name"
}
$headerPath='src/core/hle/service/ngc/guest_hid.h'
if (-not (Test-Path $headerPath -PathType Leaf)) {
    $guestHidHeader = @'
// SPDX-FileCopyrightText: Copyright 2026 Eden Emulator Project
// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once

#include "core/core.h"
#include "core/hle/kernel/k_shared_memory.h"
#include "core/hle/kernel/svc_results.h"
#include "core/hle/service/ipc_helpers.h"

namespace Service::NGC {

struct GuestHidMemoryConfig {
    u64 size;
    u64 offset;
};
static_assert(sizeof(GuestHidMemoryConfig) == 0x10);

inline void ReplyGuestHidSharedMemory(HLERequestContext& ctx, Core::System& system,
                                      Kernel::KSharedMemory*& guest_hid_memory) {
    constexpr u64 GuestHidMemorySize = 0x9b000;
    auto& kernel = system.Kernel();
    if (!guest_hid_memory) {
        auto* memory = Kernel::KSharedMemory::Create(kernel);
        const auto result =
            memory ? memory->Initialize(kernel, system.DeviceMemory(), nullptr,
                                        Kernel::Svc::MemoryPermission::ReadWrite,
                                        Kernel::Svc::MemoryPermission::Read, GuestHidMemorySize)
                   : Kernel::ResultOutOfResource;
        if (R_FAILED(result)) {
            if (memory) {
                memory->Close(kernel);
            }
            IPC::ResponseBuilder rb{ctx, 2};
            rb.Push(result);
            return;
        }
        Kernel::KSharedMemory::Register(kernel, memory);
        guest_hid_memory = memory;
        LOG_INFO(Service_NGC,
                 "GameShare guest HID shared memory: size={:#x}, offset=0, no guests connected",
                 GuestHidMemorySize);
    }
    IPC::ResponseBuilder rb{ctx, 6, 1};
    rb.Push(ResultSuccess);
    rb.PushRaw(GuestHidMemoryConfig{GuestHidMemorySize, 0});
    rb.PushCopyObjects(ctx, guest_hid_memory);
}

} // namespace Service::NGC
'@
    [IO.File]::WriteAllText($headerPath,$guestHidHeader.TrimEnd([char[]]@([char]13,[char]10)) + [string][char]10,[Text.UTF8Encoding]::new($false))
    Write-Host '[PORTED] Lichii guest HID shared memory IPC reply helper'
}
$stream='src/core/hle/service/nx2_streamplay.h'
$stIncludesOld = @'
#include "core/hle/kernel/k_event.h"
#include "core/hle/service/ipc_helpers.h"
#include "core/hle/service/kernel_helpers.h"
#include "core/hle/service/service.h"
'@
$stIncludesNew = @'
#include "core/hle/service/ipc_helpers.h"
#include "core/hle/service/ngc/guest_hid.h"
#include "core/hle/service/service.h"
'@
Replace-Unique $stream $stIncludesOld $stIncludesNew 'streamplay includes'
$stOld = @'
class INx2StreamPlayUserService final : public ServiceFramework<INx2StreamPlayUserService> {
public:
    explicit INx2StreamPlayUserService(Core::System& system_)
        : ServiceFramework{system_, "nx2:stpl:u::0"}, service_context{system_, "stpl:u"} {
        static const FunctionInfo functions[] = {
            {300, &INx2StreamPlayUserService::GetEvent, "GetEvent (guessed)"},
        };
        RegisterHandlers(functions);
        event = service_context.CreateEvent("INx2StreamPlayUserService:Event");
    }

    ~INx2StreamPlayUserService() override {
        service_context.CloseEvent(event);
    }

private:
    void GetEvent(HLERequestContext& ctx) {
        LOG_WARNING(Service, "(STUBBED) stpl:u::0 {}, returning an event", ctx.GetCommand());
        IPC::ResponseBuilder rb{ctx, 2, 1};
        rb.Push(ResultSuccess);
        rb.PushCopyObjects(ctx, event->GetReadableEvent());
    }

    KernelHelpers::ServiceContext service_context;
    Kernel::KEvent* event;
};
'@
$stNew = @'
class INx2StreamPlayUserService final : public ServiceFramework<INx2StreamPlayUserService> {
public:
    explicit INx2StreamPlayUserService(Core::System& system_)
        : ServiceFramework{system_, "nx2:stpl:u::0"} {
        static const FunctionInfo functions[] = {
            {300, &INx2StreamPlayUserService::GetGuestHidSharedMemory, "GetGuestHidSharedMemory"},
        };
        RegisterHandlers(functions);
    }

    ~INx2StreamPlayUserService() override {
        if (guest_hid_memory) {
            guest_hid_memory->Close(kernel);
        }
    }

private:
    void GetGuestHidSharedMemory(HLERequestContext& ctx) {
        NGC::ReplyGuestHidSharedMemory(ctx, system, guest_hid_memory);
    }

    Kernel::KSharedMemory* guest_hid_memory{};
};
'@
Replace-Unique $stream $stOld $stNew 'Lichii direct stpl:u route'
$ngc='src/core/hle/service/ngc/ngc.cpp'
$ngcIncludeOld = @'
#include "core/hle/service/ngc/ngc.h"
'@
$ngcIncludeNew = @'
#include "core/hle/service/ngc/guest_hid.h"
#include "core/hle/service/ngc/ngc.h"
'@
Replace-Unique $ngc $ngcIncludeOld $ngcIncludeNew 'stpl:u shim helper include'
$ngcOld = @'
class IUserShimScopedObject final : public ServiceFramework<IUserShimScopedObject> {
public:
    explicit IUserShimScopedObject(Core::System& system_)
        : ServiceFramework(system_, "IUserShimScopedObject"), service_context{system_, "stpl:u"} {
        // clang-format off
        static const FunctionInfo functions[] = {
            {300, D<&IUserShimScopedObject::GetEvent>, "GetEvent"},
            {450, nullptr, "InitializeForSaveData"},
            {451, nullptr, "FinalizeForSaveData"},
            {452, D<&IUserShimScopedObject::OpenSaveData>, "OpenSaveData"},
            {453, nullptr, "CloseSaveData"},
            {454, D<&IUserShimScopedObject::ReadSaveSlot>, "ReadSaveSlot"},
            {455, D<&IUserShimScopedObject::WriteSaveSlot>, "WriteSaveSlot"},
            {456, nullptr, "FlushSaveSlot"},
            {457, nullptr, "CommitSaveData"},
        };
        // clang-format on
        RegisterHandlers(functions);
        event = service_context.CreateEvent("IUserShimScopedObject:Event");
    }

    ~IUserShimScopedObject() override {
        service_context.CloseEvent(event);
    }

    Result GetEvent(OutCopyHandle<Kernel::KReadableEvent> out_event) {
        R_UNLESS(event != nullptr, Kernel::ResultOutOfResource);
        *out_event = &event->GetReadableEvent();
        R_SUCCEED();
    }

    Result OpenSaveData(Account::Uid unk0, Out<SaveDataHandle> unk1) {
        LOG_WARNING(Service_NGC, "stubbed");
        R_THROW(IPC::ResultNotSupported);
    }

    Result ReadSaveSlot(s32 offset, SaveDataHandle handle, OutBuffer<BufferAttr_HipcAutoSelect> out_data, Out<u32> out_size) {
        LOG_WARNING(Service_NGC, "stubbed");
        R_THROW(IPC::ResultNotSupported);
    }

    Result WriteSaveSlot(s32 offset, SaveDataHandle handle, InBuffer<BufferAttr_HipcAutoSelect> out_data) {
        LOG_WARNING(Service_NGC, "stubbed");
        // to implement
        R_SUCCEED();
    }

private:
    KernelHelpers::ServiceContext service_context;
    Kernel::KEvent* event{};
};
'@
$ngcNew = @'
class IUserShimScopedObject final : public ServiceFramework<IUserShimScopedObject> {
public:
    explicit IUserShimScopedObject(Core::System& system_)
        : ServiceFramework(system_, "IUserShimScopedObject") {
        // clang-format off
        static const FunctionInfo functions[] = {
            {300, &IUserShimScopedObject::GetGuestHidSharedMemory, "GetGuestHidSharedMemory"},
            {450, nullptr, "InitializeForSaveData"},
            {451, nullptr, "FinalizeForSaveData"},
            {452, D<&IUserShimScopedObject::OpenSaveData>, "OpenSaveData"},
            {453, nullptr, "CloseSaveData"},
            {454, D<&IUserShimScopedObject::ReadSaveSlot>, "ReadSaveSlot"},
            {455, D<&IUserShimScopedObject::WriteSaveSlot>, "WriteSaveSlot"},
            {456, nullptr, "FlushSaveSlot"},
            {457, nullptr, "CommitSaveData"},
        };
        // clang-format on
        RegisterHandlers(functions);
    }

    ~IUserShimScopedObject() override {
        if (guest_hid_memory) {
            guest_hid_memory->Close(kernel);
        }
    }

    void GetGuestHidSharedMemory(HLERequestContext& ctx) {
        ReplyGuestHidSharedMemory(ctx, system, guest_hid_memory);
    }

    Result OpenSaveData(Account::Uid unk0, Out<SaveDataHandle> unk1) {
        LOG_WARNING(Service_NGC, "stubbed");
        R_THROW(IPC::ResultNotSupported);
    }

    Result ReadSaveSlot(s32 offset, SaveDataHandle handle, OutBuffer<BufferAttr_HipcAutoSelect> out_data, Out<u32> out_size) {
        LOG_WARNING(Service_NGC, "stubbed");
        R_THROW(IPC::ResultNotSupported);
    }

    Result WriteSaveSlot(s32 offset, SaveDataHandle handle, InBuffer<BufferAttr_HipcAutoSelect> out_data) {
        LOG_WARNING(Service_NGC, "stubbed");
        // to implement
        R_SUCCEED();
    }

private:
    Kernel::KSharedMemory* guest_hid_memory{};
};
'@
Replace-Unique $ngc $ngcOld $ngcNew 'Lichii ngc stpl:u shim route'
foreach ($part in @(
    @($headerPath,'constexpr u64 GuestHidMemorySize = 0x9b000;'),
    @($headerPath,'rb.PushRaw(GuestHidMemoryConfig{GuestHidMemorySize, 0});'),
    @($stream,'NGC::ReplyGuestHidSharedMemory(ctx, system, guest_hid_memory);'),
    @($ngc,'ReplyGuestHidSharedMemory(ctx, system, guest_hid_memory);')
)) {
    if (-not (Select-String -Path $part[0] -SimpleMatch $part[1] -Quiet)) {
        throw "Lichii streamplay guest HID missing invariant: $($part[1])"
    }
}
git diff --check
if ($LASTEXITCODE -ne 0) { throw 'Lichii streamplay port failed source diff gate' }
Write-Host '[PASS] Lichii streamplay guest HID response staged; still needs C++ + IPC tests and Star Fox runtime retest'
