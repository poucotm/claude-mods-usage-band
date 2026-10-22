' Opened by a click on a usage-band notification (usageband-focus:<window handle>).
' Runs focus.ps1 with no window, so no console flashes on screen.
Dim folder
folder = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & folder & "\focus.ps1"" """ & WScript.Arguments(0) & """", 0, False
