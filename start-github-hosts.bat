@echo off
chcp 65001 >nul
REM ===========================================================================
REM  git看门狗 — 一键恢复（清除暂停标记并立即拉起代理）
REM ===========================================================================
setlocal
set "BASE=%~dp0"
set "REG=HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings"

echo [1/3] 清除暂停标记...
if exist "%BASE%.paused" del /f /q "%BASE%.paused"

echo [2/3] 启动 mitmdump（8180 端口）...
start "github-hosts" /min "%BASE%mitmdump-run.cmd"
timeout /t 6 /nobreak >nul

echo [3/3] 写入 PAC 系统代理...
reg add "%REG%" /v AutoConfigURL /t REG_SZ /d "http://127.0.0.1:8180/proxy.pac" /f >nul 2>&1
reg add "%REG%" /v ProxyEnable /t REG_DWORD /d 0 /f >nul 2>&1

echo.
echo 已启动。当前状态：
netstat -ano | findstr ":8180" | findstr "LISTENING"
echo.
pause
endlocal
