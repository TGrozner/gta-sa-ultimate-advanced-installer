#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <xinput.h>

#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <cstring>

namespace {

constexpr std::uintptr_t kGetHandBrakeAddress = 0x540040;
constexpr std::uintptr_t kGameProcessCallAddress = 0x53E981;
constexpr std::uintptr_t kGetStatValueAddress = 0x558E40;
constexpr std::uintptr_t kPcSaveHelperAddress = 0xC17034;
constexpr std::uintptr_t kSaveSlotAddress = 0x619060;
constexpr std::uintptr_t kGameStateAddress = 0xC8D4C0;
constexpr unsigned short kMissionsPassedStat = 147;
constexpr int kPlayingGameState = 9;

using HandBrakeFn = short(__attribute__((thiscall)) *)(void*);
using GameProcessFn = void(__attribute__((cdecl)) *)();
using GetStatValueFn = float(__attribute__((cdecl)) *)(unsigned short);
using SaveSlotFn = unsigned int(__attribute__((thiscall)) *)(void*, int);
using XInputGetStateFn = DWORD(WINAPI *)(DWORD, XINPUT_STATE*);

HMODULE g_module = nullptr;
HandBrakeFn g_originalHandBrake = nullptr;
GameProcessFn g_originalGameProcess = nullptr;
XInputGetStateFn g_xinputGetState = nullptr;

char g_moduleDirectory[MAX_PATH]{};
char g_gameDirectory[MAX_PATH]{};
char g_logPath[MAX_PATH]{};
char g_markerPath[MAX_PATH]{};
char g_savePath[MAX_PATH]{};

bool g_controlsEnabled = true;
bool g_autosaveEnabled = true;
bool g_autosaveOwnsSlot = false;
bool g_sessionInitialized = false;
bool g_autosavePending = false;
int g_autosaveSlot = 7;
int g_lastMissionCount = 0;
DWORD g_autosaveDelayMs = 5000;
DWORD g_autosaveDueAt = 0;
DWORD g_lastGameFrameAt = 0;

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

    const HANDLE file = CreateFileA(
        g_logPath,
        FILE_APPEND_DATA,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        nullptr,
        OPEN_ALWAYS,
        FILE_ATTRIBUTE_NORMAL,
        nullptr
    );
    if (file == INVALID_HANDLE_VALUE) {
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

HandBrakeFn CreateHandBrakeTrampoline(std::uint8_t* target) {
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
    return reinterpret_cast<HandBrakeFn>(trampoline);
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
    if (!g_controlsEnabled || g_xinputGetState == nullptr || pad == nullptr) {
        return g_originalHandBrake != nullptr ? g_originalHandBrake(pad) : 0;
    }

    XINPUT_STATE state{};
    if (g_xinputGetState(0, &state) != ERROR_SUCCESS) {
        return g_originalHandBrake != nullptr ? g_originalHandBrake(pad) : 0;
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
        return false;
    }

    DWORD written = 0;
    const BOOL success = WriteFile(file, contents, static_cast<DWORD>(length), &written, nullptr);
    CloseHandle(file);
    return success && written == static_cast<DWORD>(length);
}

void ConfigureAutosaveProtection(const char* saveDirectory) {
    CopyString(g_gameDirectory, g_savePath, sizeof(g_savePath));
    AppendPath(g_savePath, sizeof(g_savePath), "\\");
    AppendPath(g_savePath, sizeof(g_savePath), saveDirectory);
    char saveName[32]{};
    std::snprintf(saveName, sizeof(saveName), "\\GTASAsf%d.b", g_autosaveSlot);
    AppendPath(g_savePath, sizeof(g_savePath), saveName);

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

void ProcessAutosave() {
    if (!g_autosaveEnabled || *reinterpret_cast<volatile int*>(kGameStateAddress) != kPlayingGameState) {
        return;
    }

    const DWORD now = GetTickCount();
    if (g_lastGameFrameAt != 0 && now - g_lastGameFrameAt > 3000) {
        g_sessionInitialized = false;
        g_autosavePending = false;
    }
    g_lastGameFrameAt = now;

    const auto getStatValue = reinterpret_cast<GetStatValueFn>(kGetStatValueAddress);
    const int missionCount = static_cast<int>(getStatValue(kMissionsPassedStat) + 0.5f);
    if (!g_sessionInitialized || missionCount < g_lastMissionCount) {
        g_lastMissionCount = missionCount;
        g_sessionInitialized = true;
        g_autosavePending = false;
        return;
    }

    if (missionCount > g_lastMissionCount) {
        g_lastMissionCount = missionCount;
        g_autosavePending = true;
        g_autosaveDueAt = now + g_autosaveDelayMs;
        Log(
            "INFO autosave mission_count=%d slot=%d delay_ms=%lu outcome=scheduled",
            missionCount,
            g_autosaveSlot,
            static_cast<unsigned long>(g_autosaveDelayMs)
        );
    }

    if (!g_autosavePending || static_cast<LONG>(now - g_autosaveDueAt) < 0) {
        return;
    }

    g_autosavePending = false;
    const auto saveSlot = reinterpret_cast<SaveSlotFn>(kSaveSlotAddress);
    const unsigned int result = saveSlot(reinterpret_cast<void*>(kPcSaveHelperAddress), g_autosaveSlot - 1);
    if (result == 0) {
        if (!g_autosaveOwnsSlot) {
            g_autosaveOwnsSlot = ClaimAutosaveSlot();
        }
        Log(
            "INFO autosave mission_count=%d slot=%d outcome=saved marker=%s",
            missionCount,
            g_autosaveSlot,
            g_autosaveOwnsSlot ? "owned" : "write-failed"
        );
    } else {
        Log("ERROR autosave mission_count=%d slot=%d outcome=failed code=%u", missionCount, g_autosaveSlot, result);
    }
}

void __attribute__((cdecl)) GameProcessHook() {
    if (g_originalGameProcess != nullptr) {
        g_originalGameProcess();
    }
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
        g_originalHandBrake = CreateHandBrakeTrampoline(target);
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
    g_autosaveEnabled = GetPrivateProfileIntA("Autosave", "Enabled", 1, iniPath) != 0;
    g_autosaveSlot = GetPrivateProfileIntA("Autosave", "Slot", 7, iniPath);
    g_autosaveDelayMs = static_cast<DWORD>(GetPrivateProfileIntA("Autosave", "DelayMs", 5000, iniPath));
    if (g_autosaveSlot < 1 || g_autosaveSlot > 7) {
        Log("WARN autosave configured_slot=%d outcome=corrected slot=7", g_autosaveSlot);
        g_autosaveSlot = 7;
    }
    if (g_autosaveDelayMs < 1000 || g_autosaveDelayMs > 60000) {
        g_autosaveDelayMs = 5000;
    }

    char saveDirectory[MAX_PATH]{};
    GetPrivateProfileStringA("Autosave", "SaveDirectory", "userfiles", saveDirectory, MAX_PATH, iniPath);
    ConfigureAutosaveProtection(saveDirectory);
    ResolveXInput();

    const bool controlsInstalled = !g_controlsEnabled || InstallHandBrakeHook();
    const bool autosaveInstalled = !g_autosaveEnabled || InstallGameProcessHook();
    Log(
        "INFO component=GTAVEssentials controls=%s autosave=%s slot=%d outcome=ready",
        controlsInstalled ? "ready" : "failed",
        autosaveInstalled ? "ready" : "failed",
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
    CopyString(g_moduleDirectory, g_markerPath, sizeof(g_markerPath));
    AppendPath(g_markerPath, sizeof(g_markerPath), "\\GTAVEssentials.autosave-slot");

    const HANDLE thread = CreateThread(nullptr, 0, &Initialize, nullptr, 0, nullptr);
    if (thread != nullptr) {
        CloseHandle(thread);
    }
    return TRUE;
}
