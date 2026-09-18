' github-watchdog - hidden launcher for update-ips.ps1 (no console flash)
Option Explicit
Dim fso, shell, dir
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
Set shell = CreateObject("WScript.Shell")
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & fso.BuildPath(dir, "update-ips.ps1") & """", 0, False
