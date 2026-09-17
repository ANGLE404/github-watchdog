@echo off
chcp 65001 >nul
REM ===========================================================================
REM  git看门狗 — 一键停止
REM    1) 放置暂停标记 .paused（看门狗不再拉起）
REM    2) 结束 mitmdump
REM    3) 清除 PAC 系统代理 与 CLI 代理环境变量
REM  恢复：双击 start-github-hosts.bat，或重启电脑
REM ===========================================================================
setlocal
set "BASE=%~dp0"
set "REG=HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings"

echo [1/4] 写入暂停标记...
if not exist "%BASE%" mkdir "%BASE%"
echo paused > "%BASE%.paused"

echo [2/4] 结束 mitmdump 进程...
taskkill /IM mitmdump.exe /F >nul 2>&1

echo [3/4] 清除系统 PAC 代理...
reg delete "%REG%" /v AutoConfigURL /f >nul 2>&1
reg add    "%REG%" /v ProxyEnable /t REG_DWORD /d 0 /f >nul 2>&1

echo [4/4] 清除 CLI 代理环境变量...
for %%V in (HTTP_PROXY HTTPS_PROXY http_proxy https_proxy) do reg delete "HKCU\Environment" /v %%V /f >nul 2>&1

echo.
echo 已完成：git看门狗 已停止，系统代理与 CLI 环境变量已恢复默认。
echo 注意：Git 全局配置里的 http.proxy 仍保留，如需清除请运行：
echo    git config --global --unset http.proxy
echo.
pause
endlocal
