#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wincrypt.h>
#include <xinput.h>

#include <cstdarg>
#include <cstdint>
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
constexpr std::uintptr_t kFrameLimiterEnabledAddress = 0xBA6794;
constexpr char kSupportedExecutableSha256[] = "B1BAE961837F9828FB1920369390A116F5FA6BA82C547CD1DA8F2C495967ADCD";

using HandBrakeFn = short(__attribute__((thiscall)) *)(void*);
using BrakeFn = short(__attribute__((thiscall)) *)(void*);
using LookBehindFn = bool(__attribute__((thiscall)) *)(void*);
using GameProcessFn = void(__attribute__((cdecl)) *)();
using XInputGetStateFn = DWORD(WINAPI *)(DWORD, XINPUT_STATE*);

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
bool g_controlsEnabled = true;
bool g_r3LookBehindEnabled = true;
bool g_forceFrameLimiterEnabled = true;
bool g_bikeHandBrakeCall = false;
bool g_bikeRearBrakeWasActive = false;

struct PatchPlan {
    std::uint8_t* address = nullptr;
    std::size_t length = 0;
    std::uint8_t original[8]{};
    const void* destination = nullptr;
    std::uint8_t opcode = 0;
    const char* name = nullptr;
};

void CopyString(const char* source, char* destination, std::size_t capacity) {
    lstrcpynA(destination, source, static_cast<int>(capacity));
}

void CopyDirectoryFromPath(const char* source, char* destination, std::size_t capacity) {
    CopyString(source, destination, capacity);
    char* separator = std::strrchr(destination, '\\');
    if (separator != nullptr) { *separator = '\0'; }
}

void AppendPath(char* destination, std::size_t capacity, const char* suffix) {
    const std::size_t length = std::strlen(destination);
    if (length + std::strlen(suffix) + 1 < capacity) { std::strcat(destination, suffix); }
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
        line, sizeof(line), "%04u-%02u-%02u %02u:%02u:%02u.%03u %s\r\n",
        now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond, now.wMilliseconds, message
    );

    HANDLE file = CreateFileA(g_logPath, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
        nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        file = CreateFileA(g_fallbackLogPath, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
            nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    }
    if (file == INVALID_HANDLE_VALUE) { OutputDebugStringA(line); return; }
    DWORD written = 0;
    WriteFile(file, line, static_cast<DWORD>(std::strlen(line)), &written, nullptr);
    CloseHandle(file);
}

bool WriteExecutableMemory(std::uint8_t* address, const std::uint8_t* bytes, std::size_t length) {
    DWORD oldProtection = 0;
    if (!VirtualProtect(address, length, PAGE_EXECUTE_READWRITE, &oldProtection)) { return false; }
    std::memcpy(address, bytes, length);
    FlushInstructionCache(GetCurrentProcess(), address, length);
    DWORD ignored = 0;
    return VirtualProtect(address, length, oldProtection, &ignored) != FALSE;
}

bool ApplyPatch(const PatchPlan& plan) {
    std::uint8_t bytes[8]{};
    bytes[0] = plan.opcode;
    const auto relative = static_cast<std::int32_t>(
        reinterpret_cast<const std::uint8_t*>(plan.destination) - plan.address - 5
    );
    std::memcpy(bytes + 1, &relative, sizeof(relative));
    for (std::size_t index = 5; index < plan.length; ++index) { bytes[index] = 0x90; }
    return WriteExecutableMemory(plan.address, bytes, plan.length);
}

void* ResolveRelativeTarget(const std::uint8_t* address) {
    std::int32_t relative = 0;
    std::memcpy(&relative, address + 1, sizeof(relative));
    return const_cast<std::uint8_t*>(address) + 5 + relative;
}

void* CreateThiscallTrampoline(std::uint8_t* target) {
    constexpr std::size_t copiedLength = 8;
    auto* trampoline = static_cast<std::uint8_t*>(VirtualAlloc(
        nullptr, copiedLength + 5, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE
    ));
    if (trampoline == nullptr) { return nullptr; }
    std::memcpy(trampoline, target, copiedLength);
    PatchPlan returnJump{};
    returnJump.address = trampoline + copiedLength;
    returnJump.length = 5;
    returnJump.destination = target + copiedLength;
    returnJump.opcode = 0xE9;
    if (!ApplyPatch(returnJump)) {
        VirtualFree(trampoline, 0, MEM_RELEASE);
        return nullptr;
    }
    return trampoline;
}

void* PrepareThiscallHook(std::uintptr_t address, const void* hook, const char* name, PatchPlan* plan) {
    auto* target = reinterpret_cast<std::uint8_t*>(address);
    constexpr std::uint8_t expectedPrefix[8] = { 0x66, 0x83, 0xB9, 0x0E, 0x01, 0x00, 0x00, 0x00 };
    void* original = nullptr;
    std::size_t length = 0;
    if (target[0] == 0xE9) {
        original = ResolveRelativeTarget(target);
        length = 5;
    } else if (std::memcmp(target, expectedPrefix, sizeof(expectedPrefix)) == 0) {
        original = CreateThiscallTrampoline(target);
        length = sizeof(expectedPrefix);
    } else {
        Log("ERROR hook=%s outcome=refused reason=unexpected-bytes", name);
        return nullptr;
    }
    if (original == nullptr) { Log("ERROR hook=%s outcome=refused reason=trampoline-failed", name); return nullptr; }
    plan->address = target;
    plan->length = length;
    std::memcpy(plan->original, target, length);
    plan->destination = hook;
    plan->opcode = 0xE9;
    plan->name = name;
    return original;
}

bool PrepareGameProcessHook(PatchPlan* plan) {
    auto* call = reinterpret_cast<std::uint8_t*>(kGameProcessCallAddress);
    if (call[0] != 0xE8) {
        Log("ERROR hook=game-process outcome=refused reason=unexpected-opcode opcode=%02X", call[0]);
        return false;
    }
    g_originalGameProcess = reinterpret_cast<GameProcessFn>(ResolveRelativeTarget(call));
    plan->address = call;
    plan->length = 5;
    std::memcpy(plan->original, call, 5);
    plan->destination = nullptr;
    plan->opcode = 0xE8;
    plan->name = "game-process";
    return g_originalGameProcess != nullptr;
}

bool ComputeFileSha256(const char* path, char* output, std::size_t capacity) {
    if (capacity < 65) { return false; }
    HANDLE file = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
    if (file == INVALID_HANDLE_VALUE) { return false; }
    HCRYPTPROV provider = 0;
    HCRYPTHASH hash = 0;
    bool success = CryptAcquireContextA(&provider, nullptr, nullptr, PROV_RSA_AES, CRYPT_VERIFYCONTEXT) != FALSE
        && CryptCreateHash(provider, CALG_SHA_256, 0, 0, &hash) != FALSE;
    std::uint8_t buffer[65536]{};
    while (success) {
        DWORD read = 0;
        if (!ReadFile(file, buffer, sizeof(buffer), &read, nullptr)) { success = false; break; }
        if (read == 0) { break; }
        if (!CryptHashData(hash, buffer, read, 0)) { success = false; break; }
    }
    BYTE digest[32]{};
    DWORD digestLength = sizeof(digest);
    success = success && CryptGetHashParam(hash, HP_HASHVAL, digest, &digestLength, 0) != FALSE
        && digestLength == sizeof(digest);
    if (success) {
        for (DWORD index = 0; index < digestLength; ++index) {
            std::snprintf(output + index * 2, capacity - index * 2, "%02X", digest[index]);
        }
        output[64] = '\0';
    }
    if (hash != 0) { CryptDestroyHash(hash); }
    if (provider != 0) { CryptReleaseContext(provider, 0); }
    CloseHandle(file);
    return success;
}

bool IsSupportedExecutable() {
    char executablePath[MAX_PATH]{};
    char hash[65]{};
    if (GetModuleFileNameA(nullptr, executablePath, MAX_PATH) == 0 || !ComputeFileSha256(executablePath, hash, sizeof(hash))) {
        Log("ERROR executable outcome=refused reason=sha256-unavailable");
        return false;
    }
    if (lstrcmpiA(hash, kSupportedExecutableSha256) != 0) {
        Log("ERROR executable outcome=refused reason=unsupported-sha256 sha256=%s", hash);
        return false;
    }
    Log("INFO executable outcome=accepted sha256=%s", hash);
    return true;
}

void ResolveXInput() {
    const char* moduleNames[] = { "xinput1_4.dll", "xinput1_3.dll", "xinput9_1_0.dll" };
    for (const char* moduleName : moduleNames) {
        const HMODULE xinput = GetModuleHandleA(moduleName);
        if (xinput == nullptr) { continue; }
        const FARPROC procedure = GetProcAddress(xinput, "XInputGetState");
        static_assert(sizeof(procedure) == sizeof(g_xinputGetState));
        std::memcpy(&g_xinputGetState, &procedure, sizeof(g_xinputGetState));
        if (g_xinputGetState != nullptr) { Log("INFO controls xinput=%s outcome=ready", moduleName); return; }
    }
    Log("WARN controls xinput=not-found outcome=keyboard-fallback");
}

bool ControllerButtonIsDown(WORD button) {
    if (!g_controlsEnabled || g_xinputGetState == nullptr) { return false; }
    XINPUT_STATE state{};
    return g_xinputGetState(0, &state) == ERROR_SUCCESS && (state.Gamepad.wButtons & button) != 0;
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
    if (disabledControls != 0) { return 0; }
    short keyboardHandBrake = 0;
    std::memcpy(&keyboardHandBrake, static_cast<const std::uint8_t*>(pad) + 0x78 + 0x0C, sizeof(keyboardHandBrake));
    if (keyboardHandBrake != 0) { return keyboardHandBrake; }
    const WORD buttons = state.Gamepad.wButtons;
    if ((buttons & XINPUT_GAMEPAD_LEFT_SHOULDER) != 0) { return 0; }
    return (buttons & XINPUT_GAMEPAD_RIGHT_SHOULDER) != 0 ? 255 : 0;
}

short __attribute__((fastcall)) BrakeHook(void* pad, void*) {
    const bool bikeCall = g_bikeHandBrakeCall;
    g_bikeHandBrakeCall = false;
    if (g_controlsEnabled && bikeCall && g_xinputGetState != nullptr && pad != nullptr) {
        XINPUT_STATE state{};
        if (g_xinputGetState(0, &state) == ERROR_SUCCESS) {
            short disabledControls = 0;
            std::memcpy(&disabledControls, static_cast<const std::uint8_t*>(pad) + 0x10E, sizeof(disabledControls));
            const WORD buttons = state.Gamepad.wButtons;
            const bool rearBrake = disabledControls == 0
                && (buttons & XINPUT_GAMEPAD_LEFT_SHOULDER) == 0
                && (buttons & XINPUT_GAMEPAD_RIGHT_SHOULDER) != 0;
            if (rearBrake != g_bikeRearBrakeWasActive) {
                Log("INFO controls vehicle=bike binding=RB state=%s", rearBrake ? "pressed" : "released");
                g_bikeRearBrakeWasActive = rearBrake;
            }
            if (rearBrake) { return 255; }
        }
    }
    return g_originalBrake != nullptr ? g_originalBrake(pad) : 0;
}

bool __attribute__((fastcall)) LookLeftHook(void* pad, void*) {
    if (pad != nullptr && ControllerButtonIsDown(XINPUT_GAMEPAD_LEFT_SHOULDER)) { return false; }
    return g_originalLookLeft != nullptr && g_originalLookLeft(pad);
}

bool __attribute__((fastcall)) LookRightHook(void* pad, void*) {
    if (pad != nullptr && ControllerButtonIsDown(XINPUT_GAMEPAD_RIGHT_SHOULDER)) { return false; }
    return g_originalLookRight != nullptr && g_originalLookRight(pad);
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
    return disabledControls == 0 && (state.Gamepad.wButtons & XINPUT_GAMEPAD_RIGHT_THUMB) != 0;
}

void EnforceFrameLimiter() {
    if (!g_forceFrameLimiterEnabled) { return; }
    auto* enabled = reinterpret_cast<volatile bool*>(kFrameLimiterEnabledAddress);
    if (!*enabled) { *enabled = true; }
}

void __attribute__((cdecl)) GameProcessHook() {
    if (g_originalGameProcess != nullptr) { g_originalGameProcess(); }
    EnforceFrameLimiter();
}

DWORD WINAPI Initialize(void*) {
    Sleep(1500);
    if (!IsSupportedExecutable()) { return 1; }

    char iniPath[MAX_PATH]{};
    CopyString(g_moduleDirectory, iniPath, sizeof(iniPath));
    AppendPath(iniPath, sizeof(iniPath), "\\GTAVEssentials.ini");
    g_controlsEnabled = GetPrivateProfileIntA("Controls", "Enabled", 1, iniPath) != 0;
    g_r3LookBehindEnabled = GetPrivateProfileIntA("Controls", "R3LookBehind", 1, iniPath) != 0;
    g_forceFrameLimiterEnabled = GetPrivateProfileIntA("Compatibility", "ForceFrameLimiter", 1, iniPath) != 0;
    ResolveXInput();

    PatchPlan plans[6]{};
    std::size_t count = 0;
    if (g_controlsEnabled) {
        void* original = PrepareThiscallHook(kGetHandBrakeAddress, reinterpret_cast<void*>(&HandBrakeHook), "get-handbrake", &plans[count]);
        if (original == nullptr) { return 2; }
        g_originalHandBrake = reinterpret_cast<HandBrakeFn>(original); ++count;

        original = PrepareThiscallHook(kGetBrakeAddress, reinterpret_cast<void*>(&BrakeHook), "get-brake", &plans[count]);
        if (original == nullptr) { return 2; }
        g_originalBrake = reinterpret_cast<BrakeFn>(original); ++count;

        original = PrepareThiscallHook(kGetLookLeftAddress, reinterpret_cast<void*>(&LookLeftHook), "look-left", &plans[count]);
        if (original == nullptr) { return 2; }
        g_originalLookLeft = reinterpret_cast<LookBehindFn>(original); ++count;

        original = PrepareThiscallHook(kGetLookRightAddress, reinterpret_cast<void*>(&LookRightHook), "look-right", &plans[count]);
        if (original == nullptr) { return 2; }
        g_originalLookRight = reinterpret_cast<LookBehindFn>(original); ++count;

        if (g_r3LookBehindEnabled) {
            original = PrepareThiscallHook(kGetLookBehindForCarAddress, reinterpret_cast<void*>(&LookBehindForCarHook), "look-behind", &plans[count]);
            if (original == nullptr) { return 2; }
            g_originalLookBehind = reinterpret_cast<LookBehindFn>(original); ++count;
        }
    }
    if (g_forceFrameLimiterEnabled) {
        if (!PrepareGameProcessHook(&plans[count])) { return 2; }
        plans[count].destination = reinterpret_cast<void*>(&GameProcessHook);
        ++count;
    }

    std::size_t applied = 0;
    for (; applied < count; ++applied) {
        if (!ApplyPatch(plans[applied])) {
            Log("ERROR hook=%s outcome=failed reason=write-failed", plans[applied].name);
            while (applied > 0) {
                --applied;
                WriteExecutableMemory(plans[applied].address, plans[applied].original, plans[applied].length);
            }
            return 3;
        }
        Log("INFO hook=%s outcome=installed", plans[applied].name);
    }
    Log("INFO component=GTAVEssentials version=1.4.0 controls=%s frame_limiter=%s outcome=ready",
        g_controlsEnabled ? "enabled" : "disabled",
        g_forceFrameLimiterEnabled ? "forced-on" : "user-controlled");
    return 0;
}

} // namespace

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason != DLL_PROCESS_ATTACH) { return TRUE; }
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
    if (thread != nullptr) { CloseHandle(thread); }
    return TRUE;
}
