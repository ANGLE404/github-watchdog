@echo off
chcp 65001 >nul
REM ===========================================================================
REM  git看门狗 — GitHub CLI 一键登录（浏览器设备码授权，走本地 8180 加速代理）
REM ===========================================================================
setlocal
set "GH="
for /f "delims=" %%i in ('where gh 2^>nul') do if not defined GH set "GH=%%i"
if not defined GH if exist "%LOCALAPPDATA%\Programs\GitHubCLI\bin\gh.exe" set "GH=%LOCALAPPDATA%\Programs\GitHubCLI\bin\gh.exe"
if not defined GH (
  echo 未找到 gh.exe，请先安装 GitHub CLI: https://cli.github.com/
  pause
  exit /b 1
)

set "HTTP_PROXY=http://127.0.0.1:8180"
set "HTTPS_PROXY=http://127.0.0.1:8180"
set "NO_PROXY=localhost,127.0.0.1,::1"
set "CURL_CA_BUNDLE=%USERPROFILE%\.mitmproxy\git-ca-bundle.crt"

echo ============================================================
echo   GitHub CLI 登录
echo ============================================================
echo.
echo   1) 屏幕上会出现 8 位一次性代码，例如 ABCD-1234
echo   2) 浏览器打开 https://github.com/login/device 粘贴该代码
echo   3) 点 Authorize 授权，回到本窗口等待提示 Login Succeeded
echo.

"%GH%" auth login --hostname github.com --git-protocol https --web
"%GH%" auth setup-git

echo.
echo ==== 当前登录状态 ====
"%GH%" auth status
echo.
pause
endlocal
