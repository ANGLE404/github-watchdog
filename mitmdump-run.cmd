@echo off
REM ===========================================================================
REM  git看门狗 (github-watchdog) — mitmdump launcher
REM  stdin is bound to NUL and output goes to mitmdump.log; this is the only
REM  launch style that proved stable across reboots (do NOT use Start-Process
REM  mitmdump.exe directly, and do NOT add --set termlog_verbosity).
REM ===========================================================================
setlocal
set "BASE=%~dp0"
set "EXE=%BASE%bin\mitmdump.exe"
if not exist "%EXE%" set "EXE=mitmdump"
"%EXE%" -s "%BASE%src\github-hosts.py" -p 8180 --set flow_detail=0 < NUL > "%BASE%mitmdump.log" 2>&1
endlocal
