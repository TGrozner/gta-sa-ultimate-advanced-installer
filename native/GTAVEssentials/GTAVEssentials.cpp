#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <xinput.h>

#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <cstring>

namespace {

constexpr std::uintptr_t kGetHandBrakeAddress = 0x540040;
constexpr std::uintptr_t kGetBrakeAddress = 0x540080;
constexpr std::uintptr_t kGetLookLeftAddress = 0x53FDD0;
constexpr std::uintptr_t kGetLookRightAddress = 0x53FE10;
constexpr std::uintptr_t kGetLookBehindForCarAddress = 0x53FE70;
constexpr std::uintptr_t kBikeProcessControlInputsStart = 0x6BE310;
constexpr std::uintptr_t kBikeProcessControlInputsEnd = 0x6BEEB0;
constexpr std::uintptr_t kGameProcessCallAddress = 0x53E981;
constexpr std::uintptr_t kGetStatValueAddress = 0x558E40;
constexpr std::uintptr_t kSaveSlotAddress = 0x619060;
constexpr std::uintptr_t kGameStateAddress = 0xC8D4C0;
constexpr std::uintptr_t kIsPlayerOnMissionAddress = 0x464D50;
constexpr std::uintptr_t kFindPlayerPedAddress = 0x56E210;
constexpr std::uintptr_t kFindPlayerVehicleAddress = 0x56E0D0;
constexpr std::uintptr_t kActiveScriptsAddress = 0xA8B42C;
constexpr std::uintptr_t kGangWarStateAddress = 0x96AB64;
constexpr std::uintptr_t kCutsceneRunningAddress = 0xB5F851;
constexpr std::uintptr_t kCutsceneProcessingAddress = 0xB5F852;
constexpr std::uintptr_t kFrameLimiterEnabledAddress = 0xBA6794;
constexpr std::uintptr_t kMenuActiveAddress = 0xBA67A4;
constexpr std::uintptr_t kSelectedSaveGameAddress = 0xBA68A7;
constexpr std::uintptr_t kPad0DisableControlsAddress = 0xB73566;
constexpr std::uintptr_t kSaveBypassAddress = 0x61907A;
constexpr unsigned short kMissionsPassedStat = 147;
constexpr int kPlayingGameState = 9;
constexpr bool kRuntimeAutosaveSupported = false;
constexpr DWORD kSaveFileSize = 202752;
constexpr std::size_t kSaveBlockCount = 34;
constexpr std::size_t kPlayerPedSize = 548;

using HandBrakeFn = short(__attribute__((thiscall)) *)(void*);
using BrakeFn = short(__attribute__((thiscall)) *)(void*);
using LookBehindFn = bool(__attribute__((thiscall)) *)(void*);
using GameProcessFn = void(__attribute__((cdecl)) *)();
using GetStatValueFn = float(__attribute__((cdecl)) *)(unsigned short);
using SaveSlotFn = unsigned int(__attribute__((cdecl)) *)(int);
using IsPlayerOnMissionFn = bool(__attribute__((cdecl)) *)();
using FindPlayerPedFn = void*(__attribute__((cdecl)) *)(int);
using FindPlayerVehicleFn = void*(__attribute__((cdecl)) *)(int, bool);
using XInputGetStateFn = DWORD(WINAPI *)(DWORD, XINPUT_STATE*);

HMODULE g_module = nullptr;
HandBrakeFn g_originalHandBrake = nullptr;
BrakeFn g_originalBrake = nullptr;
LookBehindFn g_originalLookLeft = nullptr;
LookBehindFn g_originalLookRight = nullptr;
LookBehindFn g_originalLookBehind = nullptr;
GameProcessFn g_originalGameProcess = nullptr;
XInputGetStateFn g_xinputGetState = nullptr;

char g_moduleDirectory[MAX_PATH]{};
char g_gameDirectory[MAX_PATH]{};
char g_logPath[MAX_PATH]{};
char g_fallbackLogPath[MAX_PATH]{};
char g_markerPath[MAX_PATH]{};
char g_saveDirectoryPath[MAX_PATH]{};
char g_savePath[MAX_PATH]{};
char g_previousSavePath[MAX_PATH]{};
char g_cleoSavePath[MAX_PATH]{};
char g_previousCleoSavePath[MAX_PATH]{};

bool g_controlsEnabled = true;
bool g_r3LookBehindEnabled = true;
bool g_forceFrameLimiterEnabled = true;
bool g_autosaveEnabled = true;
bool g_autosaveOwnsSlot = false;
bool g_sessionInitialized = false;
bool g_autosavePending = false;
int g_autosaveSlot = 7;
int g_lastMissionCount = 0;
DWORD g_autosaveDelayMs = 5000;
DWORD g_autosaveSafeWindowMs = 10000;
DWORD g_autosaveDueAt = 0;
DWORD g_autosaveSafeSinceAt = 0;
DWORD g_lastGameFrameAt = 0;
const char* g_lastAutosaveUnsafeReason = nullptr;
bool g_bikeHandBrakeCall = false;
bool g_bikeRearBrakeWasActive = false;

void CopyString(const char* source, char* destination, std::size_t capacity) {
    lstrcpynA(destination, source, static_cast<int>(capacity));
}

void CopyDirectoryFromPath(const char* source, char* destination, std::size_t capacity) {
    CopyString(source, destination, capacity);
    char* separator = std::strrchr(destination, '\\');
    if (separator != nullptr) {
        *separator = '\0';
    }
}

void AppendPath(char* destination, std::size_t capacity, const char* suffix) {
    const std::size_t length = std::strlen(destination);
    if (length + std::strlen(suffix) + 1 < capacity) {
        std::strcat(destination, suffix);
    }
}

void BuildSavePath(int slot, char* destination, std::size_t capacity) {
    CopyString(g_saveDirectoryPath, destination, capacity);
    char saveName[32]{};
    std::snprintf(saveName, sizeof(saveName), "\\GTASAsf%d.b", slot);
    AppendPath(destination, capacity, saveName);
}

void Log(const char* format, ...) {
    char message[768]{};
    va_list arguments;
    va_start(arguments, format);
    std::vsnprintf(message, sizeof(message), format, arguments);
    va_end(arguments);

    SYSTEMTIME now{};
    GetLocalTime(&now);
    char line[896]{};
    std::snprintf(
        line,
        sizeof(line),
        "%04u-%02u-%02u %02u:%02u:%02u.%03u %s\r\n",
        now.wYear,
        now.wMonth,
        now.wDay,
        now.wHour,
        now.wMinute,
        now.wSecond,
        now.wMilliseconds,
        message
    );

    HANDLE file = CreateFileA(
        g_logPath,
        FILE_APPEND_DATA,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        nullptr,
        OPEN_ALWAYS,
        FILE_ATTRIBUTE_NORMAL,
        nullptr
    );
    if (file == INVALID_HANDLE_VALUE) {
        file = CreateFileA(
            g_fallbackLogPath,
            FILE_APPEND_DATA,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            nullptr,
            OPEN_ALWAYS,
            FILE_ATTRIBUTE_NORMAL,
            nullptr
        );
    }
    if (file == INVALID_HANDLE_VALUE) {
        OutputDebugStringA(line);
        return;
    }

    DWORD written = 0;
    WriteFile(file, line, static_cast<DWORD>(std::strlen(line)), &written, nullptr);
    CloseHandle(file);
}

bool PatchRelativeBranch(std::uint8_t* address, const void* destination, std::size_t patchLength, std::uint8_t opcode) {
    if (patchLength < 5) {
        return false;
    }

    DWORD oldProtection = 0;
    if (!VirtualProtect(address, patchLength, PAGE_EXECUTE_READWRITE, &oldProtection)) {
        return false;
    }

    address[0] = opcode;
    const auto relative = static_cast<std::int32_t>(
        reinterpret_cast<const std::uint8_t*>(destination) - address - 5
    );
    std::memcpy(address + 1, &relative, sizeof(relative));
    for (std::size_t index = 5; index < patchLength; ++index) {
        address[index] = 0x90;
    }

    FlushInstructionCache(GetCurrentProcess(), address, patchLength);
    DWORD ignored = 0;
    VirtualProtect(address, patchLength, oldProtection, &ignored);
    return true;
}

void* ResolveRelativeTarget(const std::uint8_t* address) {
    std::int32_t relative = 0;
    std::memcpy(&relative, address + 1, sizeof(relative));
    return const_cast<std::uint8_t*>(address) + 5 + relative;
}

void* CreateThiscallTrampoline(std::uint8_t* target) {
    constexpr std::size_t copiedLength = 8;
    auto* trampoline = static_cast<std::uint8_t*>(VirtualAlloc(
        nullptr,
        copiedLength + 5,
        MEM_COMMIT | MEM_RESERVE,
        PAGE_EXECUTE_READWRITE
    ));
    if (trampoline == nullptr) {
        return nullptr;
    }

    std::memcpy(trampoline, target, copiedLength);
    if (!PatchRelativeBranch(trampoline + copiedLength, target + copiedLength, 5, 0xE9)) {
        VirtualFree(trampoline, 0, MEM_RELEASE);
        return nullptr;
    }
    return trampoline;
}

void ResolveXInput() {
    const char* moduleNames[] = {
        "xinput1_4.dll",
        "xinput1_3.dll",
        "xinput9_1_0.dll"
    };

    for (const char* moduleName : moduleNames) {
        const HMODULE xinput = GetModuleHandleA(moduleName);
        if (xinput == nullptr) {
            continue;
        }
        const FARPROC procedure = GetProcAddress(xinput, "XInputGetState");
        static_assert(sizeof(procedure) == sizeof(g_xinputGetState));
        std::memcpy(&g_xinputGetState, &procedure, sizeof(g_xinputGetState));
        if (g_xinputGetState != nullptr) {
            Log("INFO controls xinput=%s outcome=ready", moduleName);
            return;
        }
    }
    Log("WARN controls xinput=not-found outcome=keyboard-fallback");
}

short __attribute__((fastcall)) HandBrakeHook(void* pad, void*) {
    const auto returnAddress = reinterpret_cast<std::uintptr_t>(__builtin_return_address(0));
    g_bikeHandBrakeCall = returnAddress >= kBikeProcessControlInputsStart
        && returnAddress < kBikeProcessControlInputsEnd;

    if (!g_controlsEnabled || g_xinputGetState == nullptr || pad == nullptr) {
        return g_originalHandBrake != nullptr ? g_originalHandBrake(pad) : 0;
    }

    XINPUT_STATE state{};
    if (g_xinputGetState(0, &state) != ERROR_SUCCESS) {
        return g_originalHandBrake != nullptr ? g_originalHandBrake(pad) : 0;
    }

    short disabledControls = 0;
    std::memcpy(&disabledControls, static_cast<const std::uint8_t*>(pad) + 0x10E, sizeof(disabledControls));
    if (disabledControls != 0) {
        return 0;
    }

    // Keep the keyboard handbrake available even when a controller is connected.
    const auto* bytes = static_cast<const std::uint8_t*>(pad);
    short keyboardHandBrake = 0;
    std::memcpy(&keyboardHandBrake, bytes + 0x78 + 0x0C, sizeof(keyboardHandBrake));
    if (keyboardHandBrake != 0) {
        return keyboardHandBrake;
    }

    const WORD buttons = state.Gamepad.wButtons;
    if ((buttons & XINPUT_GAMEPAD_LEFT_SHOULDER) != 0) {
        // LB changes RB from handbrake to drive-by fire, as in GTA V.
        return 0;
    }
    return (buttons & XINPUT_GAMEPAD_RIGHT_SHOULDER) != 0 ? 255 : 0;
}

short __attribute__((fastcall)) BrakeHook(void* pad, void*) {
    const bool bikeHandBrakeCall = g_bikeHandBrakeCall;
    g_bikeHandBrakeCall = false;

    if (g_controlsEnabled && bikeHandBrakeCall && g_xinputGetState != nullptr && pad != nullptr) {
        XINPUT_STATE state{};
        if (g_xinputGetState(0, &state) == ERROR_SUCCESS) {
            short disabledControls = 0;
            std::memcpy(&disabledControls, static_cast<const std::uint8_t*>(pad) + 0x10E, sizeof(disabledControls));
            const WORD buttons = state.Gamepad.wButtons;
            const bool rearBrakeActive = disabledControls == 0
                && (buttons & XINPUT_GAMEPAD_LEFT_SHOULDER) == 0
                && (buttons & XINPUT_GAMEPAD_RIGHT_SHOULDER) != 0;
            if (rearBrakeActive != g_bikeRearBrakeWasActive) {
                Log(
                    "INFO controls vehicle=bike binding=RB operation=rear-brake state=%s",
                    rearBrakeActive ? "pressed" : "released"
                );
                g_bikeRearBrakeWasActive = rearBrakeActive;
            }
            if (rearBrakeActive) {
                // Bikes consume both the handbrake flag and the regular brake
                // pressure. Supplying the latter makes RB lock the rear wheel
                // instead of only toggling the otherwise ineffective flag.
                return 255;
            }
        }
    }

    return g_originalBrake != nullptr ? g_originalBrake(pad) : 0;
}

bool __attribute__((fastcall)) LookBehindForCarHook(void* pad, void*) {
    if (!g_controlsEnabled || !g_r3LookBehindEnabled || g_xinputGetState == nullptr || pad == nullptr) {
        return g_originalLookBehind != nullptr && g_originalLookBehind(pad);
    }

    XINPUT_STATE state{};
    if (g_xinputGetState(0, &state) != ERROR_SUCCESS) {
        return g_originalLookBehind != nullptr && g_originalLookBehind(pad);
    }

    short disabledControls = 0;
    std::memcpy(&disabledControls, static_cast<const std::uint8_t*>(pad) + 0x10E, sizeof(disabledControls));
    if (disabledControls != 0) {
        return false;
    }

    // With an active controller, R3 exclusively owns vehicle rear view. This
    // prevents the old LB+RB combination from fighting the drive-by controls.
    return (state.Gamepad.wButtons & XINPUT_GAMEPAD_RIGHT_THUMB) != 0;
}

bool MarkerClaimsConfiguredSlot() {
    const HANDLE file = CreateFileA(
        g_markerPath,
        GENERIC_READ,
        FILE_SHARE_READ,
        nullptr,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        nullptr
    );
    if (file == INVALID_HANDLE_VALUE) {
        return false;
    }

    char contents[32]{};
    DWORD read = 0;
    ReadFile(file, contents, sizeof(contents) - 1, &read, nullptr);
    CloseHandle(file);
    return std::atoi(contents) == g_autosaveSlot;
}

bool ClaimAutosaveSlot() {
    char contents[32]{};
    const int length = std::snprintf(contents, sizeof(contents), "%d\r\n", g_autosaveSlot);
    const HANDLE file = CreateFileA(
        g_markerPath,
        GENERIC_WRITE,
        FILE_SHARE_READ,
        nullptr,
        CREATE_ALWAYS,
        FILE_ATTRIBUTE_NORMAL,
        nullptr
    );
    if (file == INVALID_HANDLE_VALUE) {
        Log(
            "ERROR autosave marker_path=\"%s\" outcome=write-failed win32_error=%lu",
            g_markerPath,
            static_cast<unsigned long>(GetLastError())
        );
        return false;
    }

    DWORD written = 0;
    const BOOL success = WriteFile(file, contents, static_cast<DWORD>(length), &written, nullptr);
    CloseHandle(file);
    const bool completed = success && written == static_cast<DWORD>(length);
    if (!completed) {
        Log(
            "ERROR autosave marker_path=\"%s\" outcome=write-incomplete win32_error=%lu written=%lu expected=%d",
            g_markerPath,
            static_cast<unsigned long>(GetLastError()),
            static_cast<unsigned long>(written),
            length
        );
    }
    return completed;
}

void ConfigureAutosaveProtection(const char* saveDirectory) {
    CopyString(g_gameDirectory, g_saveDirectoryPath, sizeof(g_saveDirectoryPath));
    AppendPath(g_saveDirectoryPath, sizeof(g_saveDirectoryPath), "\\");
    AppendPath(g_saveDirectoryPath, sizeof(g_saveDirectoryPath), saveDirectory);

    CopyString(g_saveDirectoryPath, g_markerPath, sizeof(g_markerPath));
    AppendPath(g_markerPath, sizeof(g_markerPath), "\\GTAVEssentials.autosave-slot");

    BuildSavePath(g_autosaveSlot, g_savePath, sizeof(g_savePath));
    CopyString(g_savePath, g_previousSavePath, sizeof(g_previousSavePath));
    AppendPath(g_previousSavePath, sizeof(g_previousSavePath), ".previous");

    CopyString(g_saveDirectoryPath, g_cleoSavePath, sizeof(g_cleoSavePath));
    char cleoName[32]{};
    std::snprintf(cleoName, sizeof(cleoName), "\\cs%d.sav", g_autosaveSlot - 1);
    AppendPath(g_cleoSavePath, sizeof(g_cleoSavePath), cleoName);
    CopyString(g_cleoSavePath, g_previousCleoSavePath, sizeof(g_previousCleoSavePath));
    AppendPath(g_previousCleoSavePath, sizeof(g_previousCleoSavePath), ".previous");

    g_autosaveOwnsSlot = MarkerClaimsConfiguredSlot();
    if (GetFileAttributesA(g_savePath) != INVALID_FILE_ATTRIBUTES && !g_autosaveOwnsSlot) {
        g_autosaveEnabled = false;
        Log(
            "WARN autosave slot=%d path=\"%s\" outcome=disabled reason=existing-user-save",
            g_autosaveSlot,
            g_savePath
        );
    }
}

bool ControllerButtonIsDown(WORD button) {
    if (!g_controlsEnabled || g_xinputGetState == nullptr) {
        return false;
    }
    XINPUT_STATE state{};
    return g_xinputGetState(0, &state) == ERROR_SUCCESS
        && (state.Gamepad.wButtons & button) != 0;
}

bool __attribute__((fastcall)) LookLeftHook(void* pad, void*) {
    if (pad != nullptr && ControllerButtonIsDown(XINPUT_GAMEPAD_LEFT_SHOULDER)) {
        return false;
    }
    return g_originalLookLeft != nullptr && g_originalLookLeft(pad);
}

bool __attribute__((fastcall)) LookRightHook(void* pad, void*) {
    if (pad != nullptr && ControllerButtonIsDown(XINPUT_GAMEPAD_RIGHT_SHOULDER)) {
        return false;
    }
    return g_originalLookRight != nullptr && g_originalLookRight(pad);
}

struct SafehouseLocation {
    std::uint8_t currentTown[4]{};
    std::uint8_t cameraPosition[12]{};
    std::uint8_t currentInterior[4]{};
    std::uint8_t playerPosition[12]{};
    std::uint8_t playerEnex[4]{};
    std::uint8_t zoneTown[4]{};
    int sourceSlot = 0;
};

bool ReadSaveFile(const char* path, std::uint8_t* data) {
    const HANDLE file = CreateFileA(
        path,
        GENERIC_READ,
        FILE_SHARE_READ,
        nullptr,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        nullptr
    );
    if (file == INVALID_HANDLE_VALUE) {
        return false;
    }
    const DWORD size = GetFileSize(file, nullptr);
    DWORD read = 0;
    const BOOL success = size == kSaveFileSize && ReadFile(file, data, kSaveFileSize, &read, nullptr);
    CloseHandle(file);
    return success && read == kSaveFileSize;
}

bool FindSaveBlocks(const std::uint8_t* data, std::size_t* blocks) {
    std::size_t count = 0;
    for (std::size_t offset = 0; offset + 5 <= kSaveFileSize - 4; ++offset) {
        if (std::memcmp(data + offset, "BLOCK", 5) != 0) {
            continue;
        }
        if (count >= kSaveBlockCount) {
            return false;
        }
        blocks[count++] = offset + 5;
        offset += 4;
    }
    return count == kSaveBlockCount;
}

std::uint32_t CalculateSaveChecksum(const std::uint8_t* data) {
    std::uint32_t checksum = 0;
    for (std::size_t offset = 0; offset < kSaveFileSize - 4; ++offset) {
        checksum += data[offset];
    }
    return checksum;
}

bool ValidateSave(const std::uint8_t* data, std::size_t* blocks) {
    if (!FindSaveBlocks(data, blocks)) {
        return false;
    }
    std::uint32_t storedChecksum = 0;
    std::memcpy(&storedChecksum, data + kSaveFileSize - 4, sizeof(storedChecksum));
    if (storedChecksum != CalculateSaveChecksum(data)) {
        return false;
    }
    std::uint32_t playerCount = 0;
    std::memcpy(&playerCount, data + blocks[2], sizeof(playerCount));
    const std::size_t block2End = blocks[3] - 5;
    return playerCount >= 1
        && blocks[0] + 0xC8 <= blocks[1] - 5
        && blocks[2] + 4 + kPlayerPedSize <= block2End
        && blocks[10] + 4 <= blocks[11] - 5;
}

bool ReadSafehouseLocation(const char* path, SafehouseLocation* location) {
    auto* data = static_cast<std::uint8_t*>(std::malloc(kSaveFileSize));
    if (data == nullptr) {
        return false;
    }
    std::size_t blocks[kSaveBlockCount]{};
    const bool valid = ReadSaveFile(path, data) && ValidateSave(data, blocks);
    if (valid) {
        std::memcpy(location->currentTown, data + blocks[0] + 0x6C, sizeof(location->currentTown));
        std::memcpy(location->cameraPosition, data + blocks[0] + 0x70, sizeof(location->cameraPosition));
        std::memcpy(location->currentInterior, data + blocks[0] + 0xC4, sizeof(location->currentInterior));
        std::memcpy(location->playerPosition, data + blocks[2] + 4 + 0x10, sizeof(location->playerPosition));
        std::memcpy(location->playerEnex, data + blocks[2] + 4 + 0x194, sizeof(location->playerEnex));
        std::memcpy(location->zoneTown, data + blocks[10], sizeof(location->zoneTown));
    }
    std::free(data);
    return valid;
}

bool FindLatestSafehouseLocation(SafehouseLocation* location) {
    FILETIME latestWriteTime{};
    bool found = false;
    for (int slot = 1; slot <= 7; ++slot) {
        if (slot == g_autosaveSlot) {
            continue;
        }
        char path[MAX_PATH]{};
        BuildSavePath(slot, path, sizeof(path));
        WIN32_FILE_ATTRIBUTE_DATA attributes{};
        if (!GetFileAttributesExA(path, GetFileExInfoStandard, &attributes)) {
            continue;
        }
        SafehouseLocation candidate{};
        if (!ReadSafehouseLocation(path, &candidate)) {
            Log("WARN autosave safehouse_slot=%d path=\"%s\" outcome=ignored reason=invalid-save", slot, path);
            continue;
        }
        if (!found || CompareFileTime(&attributes.ftLastWriteTime, &latestWriteTime) > 0) {
            *location = candidate;
            location->sourceSlot = slot;
            latestWriteTime = attributes.ftLastWriteTime;
            found = true;
        }
    }
    return found;
}

bool WriteValidatedAutosave(const SafehouseLocation* location) {
    auto* data = static_cast<std::uint8_t*>(std::malloc(kSaveFileSize));
    if (data == nullptr) {
        return false;
    }
    std::size_t blocks[kSaveBlockCount]{};
    bool valid = ReadSaveFile(g_savePath, data) && ValidateSave(data, blocks);
    if (valid && location != nullptr) {
        std::memcpy(data + blocks[0] + 0x6C, location->currentTown, sizeof(location->currentTown));
        std::memcpy(data + blocks[0] + 0x70, location->cameraPosition, sizeof(location->cameraPosition));
        std::memcpy(data + blocks[0] + 0xC4, location->currentInterior, sizeof(location->currentInterior));
        std::memcpy(data + blocks[2] + 4 + 0x10, location->playerPosition, sizeof(location->playerPosition));
        std::memcpy(data + blocks[2] + 4 + 0x194, location->playerEnex, sizeof(location->playerEnex));
        std::memcpy(data + blocks[10], location->zoneTown, sizeof(location->zoneTown));
        const std::uint32_t checksum = CalculateSaveChecksum(data);
        std::memcpy(data + kSaveFileSize - 4, &checksum, sizeof(checksum));

        const HANDLE file = CreateFileA(
            g_savePath,
            GENERIC_WRITE,
            FILE_SHARE_READ,
            nullptr,
            CREATE_ALWAYS,
            FILE_ATTRIBUTE_NORMAL,
            nullptr
        );
        DWORD written = 0;
        valid = file != INVALID_HANDLE_VALUE
            && WriteFile(file, data, kSaveFileSize, &written, nullptr)
            && written == kSaveFileSize
            && FlushFileBuffers(file);
        if (file != INVALID_HANDLE_VALUE) {
            CloseHandle(file);
        }
    }
    std::free(data);
    return valid;
}

bool BeginSaveBypass(std::uint8_t* originalBytes) {
    auto* address = reinterpret_cast<std::uint8_t*>(kSaveBypassAddress);
    constexpr std::uint8_t expected[5] = { 0xE8, 0xD1, 0xFE, 0xFF, 0xFF };
    if (std::memcmp(address, expected, sizeof(expected)) != 0) {
        Log("ERROR autosave patch=save-bypass outcome=failed reason=unexpected-bytes");
        return false;
    }
    std::memcpy(originalBytes, address, sizeof(expected));
    DWORD oldProtection = 0;
    if (!VirtualProtect(address, sizeof(expected), PAGE_EXECUTE_READWRITE, &oldProtection)) {
        return false;
    }
    std::memset(address, 0x90, sizeof(expected));
    FlushInstructionCache(GetCurrentProcess(), address, sizeof(expected));
    DWORD ignored = 0;
    VirtualProtect(address, sizeof(expected), oldProtection, &ignored);
    return true;
}

void EndSaveBypass(const std::uint8_t* originalBytes) {
    auto* address = reinterpret_cast<std::uint8_t*>(kSaveBypassAddress);
    DWORD oldProtection = 0;
    if (VirtualProtect(address, 5, PAGE_EXECUTE_READWRITE, &oldProtection)) {
        std::memcpy(address, originalBytes, 5);
        FlushInstructionCache(GetCurrentProcess(), address, 5);
        DWORD ignored = 0;
        VirtualProtect(address, 5, oldProtection, &ignored);
    }
}

void RestorePreviousAutosave(bool hadSaveBackup, bool hadCleoBackup) {
    if (hadSaveBackup) {
        CopyFileA(g_previousSavePath, g_savePath, FALSE);
    } else {
        DeleteFileA(g_savePath);
    }
    if (hadCleoBackup) {
        CopyFileA(g_previousCleoSavePath, g_cleoSavePath, FALSE);
    } else {
        DeleteFileA(g_cleoSavePath);
    }
}

const char* GetAutosaveUnsafeReason() {
    if (*reinterpret_cast<volatile int*>(kGameStateAddress) != kPlayingGameState) {
        return "game-not-playing";
    }

    const auto isPlayerOnMission = reinterpret_cast<IsPlayerOnMissionFn>(kIsPlayerOnMissionAddress);
    if (isPlayerOnMission()) {
        return "mission-active";
    }

    // The mission flag can be cleared a few frames before the mission thread
    // itself is removed. Saving during that cleanup window records transient
    // script state that the normal safehouse save flow can never capture.
    const auto* script = *reinterpret_cast<const std::uint8_t* const volatile*>(kActiveScriptsAddress);
    for (unsigned int visited = 0; script != nullptr && visited < 96; ++visited) {
        if (*(script + 0xDC) != 0) {
            return "mission-script-active";
        }
        script = *reinterpret_cast<const std::uint8_t* const*>(script);
    }

    if (*reinterpret_cast<volatile bool*>(kCutsceneRunningAddress)
        || *reinterpret_cast<volatile bool*>(kCutsceneProcessingAddress)) {
        return "cutscene-active";
    }
    if (*reinterpret_cast<volatile bool*>(kMenuActiveAddress)) {
        return "menu-active";
    }
    if (*reinterpret_cast<volatile short*>(kPad0DisableControlsAddress) != 0) {
        return "controls-disabled";
    }
    const auto findPlayerPed = reinterpret_cast<FindPlayerPedFn>(kFindPlayerPedAddress);
    if (findPlayerPed(-1) == nullptr) {
        return "player-missing";
    }
    const auto findPlayerVehicle = reinterpret_cast<FindPlayerVehicleFn>(kFindPlayerVehicleAddress);
    if (findPlayerVehicle(-1, false) != nullptr) {
        return "player-in-vehicle";
    }
    if (*reinterpret_cast<volatile int*>(kGangWarStateAddress) != 0) {
        return "gang-war-active";
    }
    return nullptr;
}

void ProcessAutosave() {
    if (!g_autosaveEnabled || *reinterpret_cast<volatile int*>(kGameStateAddress) != kPlayingGameState) {
        return;
    }

    const DWORD now = GetTickCount();
    if (g_lastGameFrameAt != 0 && now - g_lastGameFrameAt > 3000) {
        g_sessionInitialized = false;
        g_autosavePending = false;
        g_autosaveSafeSinceAt = 0;
        g_lastAutosaveUnsafeReason = nullptr;
    }
    g_lastGameFrameAt = now;

    const auto getStatValue = reinterpret_cast<GetStatValueFn>(kGetStatValueAddress);
    const int missionCount = static_cast<int>(getStatValue(kMissionsPassedStat) + 0.5f);
    if (!g_sessionInitialized || missionCount < g_lastMissionCount) {
        g_lastMissionCount = missionCount;
        g_sessionInitialized = true;
        g_autosavePending = false;
        g_autosaveSafeSinceAt = 0;
        g_lastAutosaveUnsafeReason = nullptr;
        return;
    }

    if (missionCount > g_lastMissionCount) {
        g_lastMissionCount = missionCount;
        g_autosavePending = true;
        g_autosaveDueAt = now + g_autosaveDelayMs;
        g_autosaveSafeSinceAt = 0;
        g_lastAutosaveUnsafeReason = nullptr;
        Log(
            "INFO autosave mission_count=%d slot=%d delay_ms=%lu safe_window_ms=%lu outcome=scheduled",
            missionCount,
            g_autosaveSlot,
            static_cast<unsigned long>(g_autosaveDelayMs),
            static_cast<unsigned long>(g_autosaveSafeWindowMs)
        );
    }

    if (!g_autosavePending || static_cast<LONG>(now - g_autosaveDueAt) < 0) {
        return;
    }

    const char* unsafeReason = GetAutosaveUnsafeReason();
    if (unsafeReason != nullptr) {
        g_autosaveSafeSinceAt = 0;
        if (unsafeReason != g_lastAutosaveUnsafeReason) {
            Log(
                "INFO autosave mission_count=%d slot=%d outcome=waiting reason=%s",
                missionCount,
                g_autosaveSlot,
                unsafeReason
            );
            g_lastAutosaveUnsafeReason = unsafeReason;
        }
        return;
    }

    g_lastAutosaveUnsafeReason = nullptr;
    if (g_autosaveSafeSinceAt == 0) {
        g_autosaveSafeSinceAt = now;
        Log(
            "INFO autosave mission_count=%d slot=%d safe_window_ms=%lu outcome=stabilizing",
            missionCount,
            g_autosaveSlot,
            static_cast<unsigned long>(g_autosaveSafeWindowMs)
        );
        return;
    }
    if (now - g_autosaveSafeSinceAt < g_autosaveSafeWindowMs) {
        return;
    }

    g_autosavePending = false;
    g_autosaveSafeSinceAt = 0;
    if (!g_autosaveOwnsSlot) {
        g_autosaveOwnsSlot = ClaimAutosaveSlot();
        if (!g_autosaveOwnsSlot) {
            g_autosaveEnabled = false;
            Log(
                "ERROR autosave mission_count=%d slot=%d outcome=disabled reason=marker-write-failed",
                missionCount,
                g_autosaveSlot
            );
            return;
        }
    }
    SafehouseLocation safehouseLocation{};
    const bool hasSafehouseLocation = FindLatestSafehouseLocation(&safehouseLocation);
    SafehouseLocation previousLocation{};
    const bool previousSaveWasValid = ReadSafehouseLocation(g_savePath, &previousLocation);
    const bool hadSaveBackup = previousSaveWasValid && CopyFileA(g_savePath, g_previousSavePath, FALSE);
    const bool previousCleoExists = GetFileAttributesA(g_cleoSavePath) != INVALID_FILE_ATTRIBUTES;
    const bool hadCleoBackup = previousCleoExists
        && CopyFileA(g_cleoSavePath, g_previousCleoSavePath, FALSE);

    if ((previousSaveWasValid && !hadSaveBackup) || (previousCleoExists && !hadCleoBackup)) {
        DeleteFileA(g_previousSavePath);
        DeleteFileA(g_previousCleoSavePath);
        Log("ERROR autosave mission_count=%d slot=%d outcome=failed reason=backup-write-failed", missionCount, g_autosaveSlot);
        return;
    }

    std::uint8_t saveBypassBytes[5]{};
    if (!BeginSaveBypass(saveBypassBytes)) {
        DeleteFileA(g_previousSavePath);
        DeleteFileA(g_previousCleoSavePath);
        Log("ERROR autosave mission_count=%d slot=%d outcome=failed reason=save-bypass-unavailable", missionCount, g_autosaveSlot);
        return;
    }

    const auto saveSlot = reinterpret_cast<SaveSlotFn>(kSaveSlotAddress);
    auto* selectedSaveGame = reinterpret_cast<volatile unsigned char*>(kSelectedSaveGameAddress);
    const unsigned char previousSelectedSaveGame = *selectedSaveGame;
    *selectedSaveGame = static_cast<unsigned char>(g_autosaveSlot - 1);
    const unsigned int result = saveSlot(g_autosaveSlot - 1);
    *selectedSaveGame = previousSelectedSaveGame;
    EndSaveBypass(saveBypassBytes);

    const bool validated = result == 0
        && WriteValidatedAutosave(hasSafehouseLocation ? &safehouseLocation : nullptr);
    if (validated) {
        Log(
            "INFO autosave mission_count=%d slot=%d safehouse_slot=%d outcome=saved marker=owned location=%s",
            missionCount,
            g_autosaveSlot,
            hasSafehouseLocation ? safehouseLocation.sourceSlot : 0,
            hasSafehouseLocation ? "last-safehouse" : "current"
        );
    } else {
        RestorePreviousAutosave(hadSaveBackup, hadCleoBackup);
        Log(
            "ERROR autosave mission_count=%d slot=%d outcome=rolled-back code=%u validation=%s previous_save=%s",
            missionCount,
            g_autosaveSlot,
            result,
            result == 0 ? "failed" : "not-run",
            hadSaveBackup ? "restored" : "removed"
        );
    }
    DeleteFileA(g_previousSavePath);
    DeleteFileA(g_previousCleoSavePath);
}

void EnforceFrameLimiter() {
    if (!g_forceFrameLimiterEnabled) {
        return;
    }

    auto* frameLimiterEnabled = reinterpret_cast<volatile bool*>(kFrameLimiterEnabledAddress);
    if (!*frameLimiterEnabled) {
        *frameLimiterEnabled = true;
        Log("INFO compatibility setting=frame-limiter value=enabled outcome=corrected");
    }
}

void __attribute__((cdecl)) GameProcessHook() {
    if (g_originalGameProcess != nullptr) {
        g_originalGameProcess();
    }
    EnforceFrameLimiter();
    ProcessAutosave();
}

bool InstallHandBrakeHook() {
    auto* target = reinterpret_cast<std::uint8_t*>(kGetHandBrakeAddress);
    constexpr std::uint8_t expectedPrefix[8] = { 0x66, 0x83, 0xB9, 0x0E, 0x01, 0x00, 0x00, 0x00 };

    std::size_t patchLength = 0;
    if (target[0] == 0xE9) {
        g_originalHandBrake = reinterpret_cast<HandBrakeFn>(ResolveRelativeTarget(target));
        patchLength = 5;
    } else if (std::memcmp(target, expectedPrefix, sizeof(expectedPrefix)) == 0) {
        g_originalHandBrake = reinterpret_cast<HandBrakeFn>(CreateThiscallTrampoline(target));
        patchLength = sizeof(expectedPrefix);
    } else {
        Log("ERROR controls hook=get-handbrake outcome=skipped reason=unexpected-bytes");
        return false;
    }

    if (g_originalHandBrake == nullptr || !PatchRelativeBranch(target, reinterpret_cast<void*>(&HandBrakeHook), patchLength, 0xE9)) {
        Log("ERROR controls hook=get-handbrake outcome=failed");
        return false;
    }
    Log("INFO controls hook=get-handbrake outcome=installed");
    return true;
}

bool InstallBrakeHook() {
    auto* target = reinterpret_cast<std::uint8_t*>(kGetBrakeAddress);
    constexpr std::uint8_t expectedPrefix[8] = { 0x66, 0x83, 0xB9, 0x0E, 0x01, 0x00, 0x00, 0x00 };

    std::size_t patchLength = 0;
    if (target[0] == 0xE9) {
        g_originalBrake = reinterpret_cast<BrakeFn>(ResolveRelativeTarget(target));
        patchLength = 5;
    } else if (std::memcmp(target, expectedPrefix, sizeof(expectedPrefix)) == 0) {
        g_originalBrake = reinterpret_cast<BrakeFn>(CreateThiscallTrampoline(target));
        patchLength = sizeof(expectedPrefix);
    } else {
        Log("ERROR controls hook=get-brake outcome=skipped reason=unexpected-bytes");
        return false;
    }

    if (g_originalBrake == nullptr || !PatchRelativeBranch(target, reinterpret_cast<void*>(&BrakeHook), patchLength, 0xE9)) {
        Log("ERROR controls hook=get-brake outcome=failed");
        return false;
    }
    Log("INFO controls hook=get-brake vehicle=bike binding=RB outcome=installed");
    return true;
}

bool InstallSideLookHook(
    std::uintptr_t address,
    LookBehindFn* original,
    const void* hook,
    const char* operation
) {
    auto* target = reinterpret_cast<std::uint8_t*>(address);
    constexpr std::uint8_t expectedPrefix[8] = { 0x66, 0x83, 0xB9, 0x0E, 0x01, 0x00, 0x00, 0x00 };

    std::size_t patchLength = 0;
    if (target[0] == 0xE9) {
        *original = reinterpret_cast<LookBehindFn>(ResolveRelativeTarget(target));
        patchLength = 5;
    } else if (std::memcmp(target, expectedPrefix, sizeof(expectedPrefix)) == 0) {
        *original = reinterpret_cast<LookBehindFn>(CreateThiscallTrampoline(target));
        patchLength = sizeof(expectedPrefix);
    } else {
        Log("ERROR controls hook=%s outcome=skipped reason=unexpected-bytes", operation);
        return false;
    }

    if (*original == nullptr || !PatchRelativeBranch(target, hook, patchLength, 0xE9)) {
        Log("ERROR controls hook=%s outcome=failed", operation);
        return false;
    }
    Log("INFO controls hook=%s controller=blocked keyboard=preserved outcome=installed", operation);
    return true;
}

bool InstallLookBehindHook() {
    auto* target = reinterpret_cast<std::uint8_t*>(kGetLookBehindForCarAddress);
    constexpr std::uint8_t expectedPrefix[8] = { 0x66, 0x83, 0xB9, 0x0E, 0x01, 0x00, 0x00, 0x00 };

    std::size_t patchLength = 0;
    if (target[0] == 0xE9) {
        g_originalLookBehind = reinterpret_cast<LookBehindFn>(ResolveRelativeTarget(target));
        patchLength = 5;
    } else if (std::memcmp(target, expectedPrefix, sizeof(expectedPrefix)) == 0) {
        g_originalLookBehind = reinterpret_cast<LookBehindFn>(CreateThiscallTrampoline(target));
        patchLength = sizeof(expectedPrefix);
    } else {
        Log("ERROR controls hook=look-behind-for-car outcome=skipped reason=unexpected-bytes");
        return false;
    }

    if (g_originalLookBehind == nullptr || !PatchRelativeBranch(target, reinterpret_cast<void*>(&LookBehindForCarHook), patchLength, 0xE9)) {
        Log("ERROR controls hook=look-behind-for-car outcome=failed");
        return false;
    }
    Log("INFO controls hook=look-behind-for-car binding=R3 outcome=installed");
    return true;
}

bool InstallGameProcessHook() {
    auto* call = reinterpret_cast<std::uint8_t*>(kGameProcessCallAddress);
    if (call[0] != 0xE8) {
        Log("ERROR autosave hook=game-process outcome=skipped reason=unexpected-opcode opcode=%02X", call[0]);
        return false;
    }

    g_originalGameProcess = reinterpret_cast<GameProcessFn>(ResolveRelativeTarget(call));
    if (!PatchRelativeBranch(call, reinterpret_cast<void*>(&GameProcessHook), 5, 0xE8)) {
        Log("ERROR autosave hook=game-process outcome=failed");
        return false;
    }
    Log("INFO autosave hook=game-process outcome=installed");
    return true;
}

DWORD WINAPI Initialize(void*) {
    Sleep(1500);

    char iniPath[MAX_PATH]{};
    CopyString(g_moduleDirectory, iniPath, sizeof(iniPath));
    AppendPath(iniPath, sizeof(iniPath), "\\GTAVEssentials.ini");

    g_controlsEnabled = GetPrivateProfileIntA("Controls", "Enabled", 1, iniPath) != 0;
    g_r3LookBehindEnabled = GetPrivateProfileIntA("Controls", "R3LookBehind", 1, iniPath) != 0;
    g_forceFrameLimiterEnabled = GetPrivateProfileIntA("Compatibility", "ForceFrameLimiter", 1, iniPath) != 0;
    const bool autosaveRequested = GetPrivateProfileIntA("Autosave", "Enabled", 0, iniPath) != 0;
    g_autosaveEnabled = autosaveRequested && kRuntimeAutosaveSupported;
    g_autosaveSlot = GetPrivateProfileIntA("Autosave", "Slot", 7, iniPath);
    g_autosaveDelayMs = static_cast<DWORD>(GetPrivateProfileIntA("Autosave", "DelayMs", 5000, iniPath));
    g_autosaveSafeWindowMs = static_cast<DWORD>(GetPrivateProfileIntA("Autosave", "SafeWindowMs", 10000, iniPath));
    if (g_autosaveSlot < 1 || g_autosaveSlot > 7) {
        Log("WARN autosave configured_slot=%d outcome=corrected slot=7", g_autosaveSlot);
        g_autosaveSlot = 7;
    }
    if (g_autosaveDelayMs < 1000 || g_autosaveDelayMs > 60000) {
        g_autosaveDelayMs = 5000;
    }
    if (g_autosaveSafeWindowMs < 5000 || g_autosaveSafeWindowMs > 60000) {
        g_autosaveSafeWindowMs = 10000;
    }

    char saveDirectory[MAX_PATH]{};
    GetPrivateProfileStringA("Autosave", "SaveDirectory", "userfiles", saveDirectory, MAX_PATH, iniPath);
    if (g_autosaveEnabled) {
        ConfigureAutosaveProtection(saveDirectory);
    } else if (autosaveRequested) {
        Log("WARN autosave outcome=disabled reason=unsafe-runtime-save-path");
    }
    ResolveXInput();

    const bool handBrakeInstalled = !g_controlsEnabled || InstallHandBrakeHook();
    const bool brakeInstalled = !g_controlsEnabled || InstallBrakeHook();
    const bool lookLeftInstalled = !g_controlsEnabled || InstallSideLookHook(
        kGetLookLeftAddress,
        &g_originalLookLeft,
        reinterpret_cast<void*>(&LookLeftHook),
        "look-left"
    );
    const bool lookRightInstalled = !g_controlsEnabled || InstallSideLookHook(
        kGetLookRightAddress,
        &g_originalLookRight,
        reinterpret_cast<void*>(&LookRightHook),
        "look-right"
    );
    const bool lookBehindInstalled = !g_controlsEnabled || !g_r3LookBehindEnabled || InstallLookBehindHook();
    const bool gameProcessInstalled = (!g_autosaveEnabled && !g_forceFrameLimiterEnabled) || InstallGameProcessHook();
    Log(
        "INFO component=GTAVEssentials controls=%s autosave=%s frame_limiter=%s slot=%d outcome=ready",
        handBrakeInstalled && brakeInstalled && lookLeftInstalled && lookRightInstalled && lookBehindInstalled ? "ready" : "failed",
        g_autosaveEnabled ? (gameProcessInstalled ? "ready" : "failed") : "disabled",
        g_forceFrameLimiterEnabled ? "forced-on" : "user-controlled",
        g_autosaveSlot
    );
    return 0;
}

} // namespace

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason != DLL_PROCESS_ATTACH) {
        return TRUE;
    }

    g_module = module;
    DisableThreadLibraryCalls(module);

    char modulePath[MAX_PATH]{};
    char executablePath[MAX_PATH]{};
    GetModuleFileNameA(module, modulePath, MAX_PATH);
    GetModuleFileNameA(nullptr, executablePath, MAX_PATH);
    CopyDirectoryFromPath(modulePath, g_moduleDirectory, sizeof(g_moduleDirectory));
    CopyDirectoryFromPath(executablePath, g_gameDirectory, sizeof(g_gameDirectory));

    CopyString(g_moduleDirectory, g_logPath, sizeof(g_logPath));
    AppendPath(g_logPath, sizeof(g_logPath), "\\GTAVEssentials.log");
    CopyString(g_gameDirectory, g_fallbackLogPath, sizeof(g_fallbackLogPath));
    AppendPath(g_fallbackLogPath, sizeof(g_fallbackLogPath), "\\GTAVEssentials.log");
    const HANDLE thread = CreateThread(nullptr, 0, &Initialize, nullptr, 0, nullptr);
    if (thread != nullptr) {
        CloseHandle(thread);
    }
    return TRUE;
}
