@echo off
chcp 65001 >nul
REM ===========================================================================
REM  git-watchdog status check -- double-click to see whether the "web + CLI"
REM  chain is healthy. This is the batch twin of selfcheck.ps1 (quick glance).
REM ===========================================================================
setlocal enabledelayedexpansion
set "BASE=%~dp0"
set "REG=HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
set "HTTP_PROXY=http://127.0.0.1:8180"
set "HTTPS_PROXY=http://127.0.0.1:8180"

echo ============================================================
echo   git-watchdog - status check
echo ============================================================
echo.

echo [process] mitmdump
tasklist /fi "imagename eq mitmdump.exe" /nh 2>nul | findstr /i mitmdump >nul
if errorlevel 1 (echo    X not running) else (echo    OK running)

echo.
echo [port] 8180 listening
netstat -ano | findstr ":8180" | findstr "LISTENING" >nul
if errorlevel 1 (echo    X not listening) else (echo    OK listening)

echo.
echo [system PAC proxy] AutoConfigURL
reg query "%REG%" /v AutoConfigURL 2>nul | findstr "proxy.pac" >nul
if errorlevel 1 (echo    X not set - browser will not use the proxy) else (echo    OK http://127.0.0.1:8180/proxy.pac)

echo.
echo [CLI env] HKCU\Environment
reg query "HKCU\Environment" /v HTTPS_PROXY 2>nul | findstr "8180" >nul
if errorlevel 1 (echo    X HTTPS_PROXY not set - git/curl will not use the proxy) else (echo    OK HTTPS_PROXY = http://127.0.0.1:8180)

echo.
echo [pause sentinel] .paused
if exist "%BASE%.paused" (echo    ! present - manually stopped, watchdog will not revive) else (echo    OK absent - proxy under automatic maintenance)

echo.
echo ============================================================
echo   live chain test (CLI via env proxy)
echo ============================================================
for %%U in (
  "https://github.com|main site github.com"
  "https://api.github.com/rate_limit|REST API"
  "https://raw.githubusercontent.com/git/git/master/README.md|raw file"
  "https://codeload.github.com/feng2208/github-hosts/zip/refs/heads/main|codeload zip"
  "https://avatars.githubusercontent.com/u/1|avatar CDN"
  "https://gist.github.com/|Gist"
  "https://www.baidu.com|non-GitHub site (should go direct)"
) do (
  for /f "tokens=1,2 delims=|" %%A in (%%U) do (
    for /f %%C in ('curl.exe -sS -o NUL -w "%%{http_code}" --max-time 25 "%%~A" 2^>nul') do (
      echo    %%B  -^>  HTTP %%C
    )
  )
)

echo.
echo Tip: if an entry shows 000 or an unexpected code, double-click start-github-hosts.bat to restart the proxy.
echo.
pause
endlocal
