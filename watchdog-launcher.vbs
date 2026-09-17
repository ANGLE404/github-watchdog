' git看门狗 (github-watchdog) — launches watchdog.ps1 fully hidden (no console flash)
Option Explicit
Dim fso, shell, dir, ps1
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(dir, "watchdog.ps1")
Set shell = CreateObject("WScript.Shell")
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """", 0, False
