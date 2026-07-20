$logPath = Join-Path $PSScriptRoot 'f8-kill-switch.log'

Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class GTAF8KillSwitch {
    [StructLayout(LayoutKind.Sequential)]
    private struct MSG {
        public IntPtr hwnd;
        public uint message;
        public UIntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public int ptX;
        public int ptY;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint key);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll")]
    private static extern int GetMessage(out MSG message, IntPtr hWnd, uint min, uint max);

    public static void Run(string logPath) {
        const int hotkeyId = 0x475441;
        const uint noRepeat = 0x4000;
        const uint f8 = 0x77;
        const uint wmHotkey = 0x0312;

        if (!RegisterHotKey(IntPtr.Zero, hotkeyId, noRepeat, f8)) {
            System.IO.File.AppendAllText(logPath, DateTimeOffset.Now.ToString("o") + " REGISTER_FAILED error=" + Marshal.GetLastWin32Error() + Environment.NewLine);
            return;
        }

        System.IO.File.AppendAllText(logPath, DateTimeOffset.Now.ToString("o") + " READY_REGISTERED hotkey=F8" + Environment.NewLine);
        try {
            MSG message;
            while (GetMessage(out message, IntPtr.Zero, 0, 0) > 0) {
                if (message.message != wmHotkey || message.wParam.ToUInt64() != (ulong)hotkeyId) continue;
                foreach (Process process in Process.GetProcessesByName("gta_sa")) {
                    try {
                        System.IO.File.AppendAllText(logPath, DateTimeOffset.Now.ToString("o") + " F8_KILL pid=" + process.Id + Environment.NewLine);
                        process.Kill();
                    } catch (Exception error) {
                        System.IO.File.AppendAllText(logPath, DateTimeOffset.Now.ToString("o") + " KILL_FAILED " + error.Message + Environment.NewLine);
                    }
                }
            }
        } finally {
            UnregisterHotKey(IntPtr.Zero, hotkeyId);
        }
    }
}
'@

[GTAF8KillSwitch]::Run($logPath)

