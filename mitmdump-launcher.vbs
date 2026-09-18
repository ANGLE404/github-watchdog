' github-watchdog - hidden launcher for mitmdump-run.cmd (no console flash)
Option Explicit
Dim fso, shell, dir
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
Set shell = CreateObject("WScript.Shell")
shell.Run "cmd.exe /c """ & fso.BuildPath(dir, "mitmdump-run.cmd") & """", 0, False
