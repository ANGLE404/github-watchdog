@echo off
REM ===========================================================================
REM  github-watchdog :: git shim (download acceleration)
REM  On clone/fetch/pull/submodule it fires a debounced, backgrounded re-pick of
REM  the fastest GitHub mirror, then runs the real git immediately (non-blocking).
REM  Installed by mirror\install-mirror.ps1 (adds this dir to PATH via $PROFILE).
REM ===========================================================================
setlocal EnableExtensions

set "MIRROR=%~dp0.."
set "REALGIT="
if exist "%ProgramFiles%\Git\cmd\git.exe"                                  set "REALGIT=%ProgramFiles%\Git\cmd\git.exe"
if not defined REALGIT if exist "%ProgramFiles(x86)%\Git\cmd\git.exe"      set "REALGIT=%ProgramFiles(x86)%\Git\cmd\git.exe"
if not defined REALGIT if exist "%LOCALAPPDATA%\Programs\Git\cmd\git.exe"  set "REALGIT=%LOCALAPPDATA%\Programs\Git\cmd\git.exe"
if not defined REALGIT set "REALGIT=git.exe"

set "SUB=%~1"
if /i "%SUB%"=="clone"     goto refresh
if /i "%SUB%"=="fetch"     goto refresh
if /i "%SUB%"=="pull"      goto refresh
if /i "%SUB%"=="submodule" goto refresh
goto run

:refresh
start "" /b powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%MIRROR%\gh-apply.ps1" -Auto >nul 2>nul

:run
"%REALGIT%" %*
exit /b %ERRORLEVEL%
