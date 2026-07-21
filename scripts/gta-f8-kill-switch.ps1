[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$ProcessId,
    [Parameter(Mandatory)][string]$ExpectedExecutable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$expected = [System.IO.Path]::GetFullPath($ExpectedExecutable)
$logPath = Join-Path $PSScriptRoot 'f8-kill-switch.log'

Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class GTAF8KillSwitch {
    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int x; public int y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG {
        public IntPtr hwnd;
        public uint message;
        public UIntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public POINT point;
    }

    private const uint SYNCHRONIZE = 0x00100000;
    private const uint PROCESS_TERMINATE = 0x0001;
    private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    private const uint WAIT_OBJECT_0 = 0;
    private const uint WAIT_TIMEOUT = 0x102;
    private const uint QS_ALLINPUT = 0x04FF;
    private const uint PM_REMOVE = 0x0001;
    private const uint WM_HOTKEY = 0x0312;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder path, ref uint size);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr window, int id);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint MsgWaitForMultipleObjects(uint count, IntPtr[] handles, bool waitAll, uint milliseconds, uint wakeMask);

    [DllImport("user32.dll")]
    private static extern bool PeekMessage(out MSG message, IntPtr window, uint min, uint max, uint remove);

    private static void Log(string logPath, string message) {
        try { File.AppendAllText(logPath, DateTimeOffset.Now.ToString("o") + " " + message + Environment.NewLine); }
        catch { }
    }

    private static bool MatchesExecutable(IntPtr process, string expected) {
        var path = new StringBuilder(32768);
        uint length = (uint)path.Capacity;
        return QueryFullProcessImageName(process, 0, path, ref length) &&
            String.Equals(Path.GetFullPath(path.ToString()), Path.GetFullPath(expected), StringComparison.OrdinalIgnoreCase);
    }

    public static int Run(int processId, string expectedExecutable, string logPath) {
        const int hotkeyId = 0x475441;
        const uint noRepeat = 0x4000;
        const uint f8 = 0x77;

        IntPtr process = OpenProcess(SYNCHRONIZE | PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
        if (process == IntPtr.Zero) { Log(logPath, "OPEN_FAILED pid=" + processId + " error=" + Marshal.GetLastWin32Error()); return 2; }
        try {
            if (!MatchesExecutable(process, expectedExecutable)) { Log(logPath, "PATH_MISMATCH pid=" + processId); return 3; }
            if (!RegisterHotKey(IntPtr.Zero, hotkeyId, noRepeat, f8)) {
                Log(logPath, "REGISTER_FAILED pid=" + processId + " error=" + Marshal.GetLastWin32Error());
                return 4;
            }
            Log(logPath, "READY pid=" + processId + " path=" + expectedExecutable);
            try {
                var handles = new[] { process };
                while (true) {
                    uint wait = MsgWaitForMultipleObjects(1, handles, false, 1000, QS_ALLINPUT);
                    if (wait == WAIT_OBJECT_0) { Log(logPath, "EXITED pid=" + processId); return 0; }
                    if (wait == WAIT_TIMEOUT) { continue; }
                    if (wait != WAIT_OBJECT_0 + 1) { Log(logPath, "WAIT_FAILED pid=" + processId + " code=" + wait); return 5; }

                    MSG message;
                    while (PeekMessage(out message, IntPtr.Zero, 0, 0, PM_REMOVE)) {
                        if (message.message != WM_HOTKEY || message.wParam.ToUInt64() != (ulong)hotkeyId) { continue; }
                        if (!MatchesExecutable(process, expectedExecutable)) { Log(logPath, "KILL_REFUSED_PATH_CHANGED pid=" + processId); return 6; }
                        try {
                            Log(logPath, "F8_KILL pid=" + processId);
                            Process.GetProcessById(processId).Kill();
                            return 0;
                        } catch (Exception error) {
                            Log(logPath, "KILL_FAILED pid=" + processId + " error=" + error.Message);
                            return 7;
                        }
                    }
                }
            } finally {
                UnregisterHotKey(IntPtr.Zero, hotkeyId);
            }
        } finally {
            CloseHandle(process);
        }
    }
}
'@

exit [GTAF8KillSwitch]::Run($ProcessId, $expected, $logPath)
