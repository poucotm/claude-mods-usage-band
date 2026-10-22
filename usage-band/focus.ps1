# Brings a window to the front: opened by a click on a usage-band notification as
#   usageband-focus:<window handle>
param([string]$Uri)

$handle = 0L

if (-not [Int64]::TryParse(($Uri -replace '^usageband-focus:/*', '').TrimEnd('/'), [ref]$handle)) {
    exit
}

Add-Type -Namespace W -Name F -MemberDefinition (@(
    '[DllImport("user32.dll")] public static extern bool IsWindow(System.IntPtr h);'
    '[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);'
    '[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);'
    '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);'
    '[DllImport("user32.dll")] public static extern bool BringWindowToTop(System.IntPtr h);'
    '[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();'
    '[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, System.IntPtr p);'
    '[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();'
    '[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);'
    '[DllImport("user32.dll")] public static extern void SwitchToThisWindow(System.IntPtr h, bool altTab);'
    '[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);'
) -join "`n")

$window = [System.IntPtr]$handle

if (-not [W.F]::IsWindow($window)) {
    exit
}

if ([W.F]::IsIconic($window)) {
    [void][W.F]::ShowWindow($window, 9) # SW_RESTORE
}

# Windows lets a process take the foreground only under conditions: a released Alt key
# counts as input, and joining the current foreground window's input thread lifts the lock.
[W.F]::keybd_event(0x12, 0, 0, [System.UIntPtr]::Zero)
[W.F]::keybd_event(0x12, 0, 2, [System.UIntPtr]::Zero)

$front = [W.F]::GetWindowThreadProcessId([W.F]::GetForegroundWindow(), [System.IntPtr]::Zero)
$self = [W.F]::GetCurrentThreadId()
$attached = [W.F]::AttachThreadInput($self, $front, $true)
[void][W.F]::BringWindowToTop($window)
$ok = [W.F]::SetForegroundWindow($window)

if ($attached) {
    [void][W.F]::AttachThreadInput($self, $front, $false)
}

if (-not $ok) {
    [W.F]::SwitchToThisWindow($window, $true)
}
