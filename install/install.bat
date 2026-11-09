@echo off
setlocal EnableExtensions
title Hermes session-lock plugin installer
echo ============================================================
echo   Hermes "session-lock" plugin  -  installer
echo   (release the "This chat is open somewhere else" lock)
echo ============================================================
echo.

set "ROOT=%~dp0.."
set "DASH=%ROOT%\dashboard"
set "DESK=%ROOT%\desktop"

if not exist "%DASH%\plugin_api.py" goto :nopayload
if not exist "%DASH%\manifest.json" goto :nopayload
if not exist "%DESK%\plugin.js" goto :nopayload

rem ---------- 1. find the Hermes home ----------
set "HH=%HERMES_HOME%"
if not "%HH%"=="" goto :havehh
if exist "%LOCALAPPDATA%\hermes\config.yaml" set "HH=%LOCALAPPDATA%\hermes"
if not "%HH%"=="" goto :havehh
if exist "%USERPROFILE%\.hermes\config.yaml" set "HH=%USERPROFILE%\.hermes"
:havehh
if "%HH%"=="" goto :nohh
if not exist "%HH%\config.yaml" goto :nohh

echo [1/4] Hermes home : %HH%
if exist "%HH%\hermes-agent\hermes_cli\active_sessions.py" (
  echo       lease registry: found
) else (
  if exist "%HH%\runtime" (
    echo       lease registry: runtime folder present
  ) else (
    echo       WARNING: neither hermes-agent\hermes_cli\active_sessions.py nor a
    echo                runtime folder was found - this Hermes build may not have
    echo                session locks at all. Continuing anyway.
  )
)

rem ---------- 2. copy the plugin halves ----------
echo [2/4] Copying plugin files...
if not exist "%HH%\plugins" mkdir "%HH%\plugins" 2>nul
if not exist "%HH%\plugins\session-lock" mkdir "%HH%\plugins\session-lock" 2>nul
if not exist "%HH%\plugins\session-lock\dashboard" mkdir "%HH%\plugins\session-lock\dashboard" 2>nul
if not exist "%HH%\desktop-plugins" mkdir "%HH%\desktop-plugins" 2>nul
if not exist "%HH%\desktop-plugins\session-lock" mkdir "%HH%\desktop-plugins\session-lock" 2>nul

copy /Y "%DASH%\plugin_api.py" "%HH%\plugins\session-lock\dashboard\plugin_api.py" >nul || goto :copyfail
copy /Y "%DASH%\manifest.json"  "%HH%\plugins\session-lock\dashboard\manifest.json"  >nul || goto :copyfail
copy /Y "%DESK%\plugin.js"      "%HH%\desktop-plugins\session-lock\plugin.js"       >nul || goto :copyfail
echo       %HH%\plugins\session-lock\dashboard\plugin_api.py
echo       %HH%\desktop-plugins\session-lock\plugin.js

rem ---------- 3. enable the Python half ----------
echo [3/4] Enabling the backend half (plugins.enabled)...
where hermes >nul 2>nul
if errorlevel 1 goto :nohermes

hermes config get plugins.enabled 2>nul | findstr /C:"session-lock" >nul
if not errorlevel 1 (
  echo       already listed in plugins.enabled - nothing to do
  goto :enabled
)
hermes config get plugins.enabled 2>nul | findstr /R /C:"^  *-" >nul
if not errorlevel 1 (
  echo       WARNING: plugins.enabled already has other entries. Not touching it.
  echo       Add this plugin yourself in PowerShell, then re-run:
  echo           hermes config set plugins.enabled '[... existing ..., "session-lock"]'
  goto :enabled
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$q=[char]34; $v='['+$q+'session-lock'+$q+']'; & hermes config set plugins.enabled $v" >nul 2>nul
if errorlevel 1 goto :enablefail
hermes config get plugins.enabled 2>nul | findstr /C:"session-lock" >nul
if errorlevel 1 goto :enablefail
echo       enabled

:enabled
rem ---------- 4. report ----------
echo [4/4] Done.
echo.
for /f "delims=" %%V in ('hermes --version 2^>nul') do echo   %%V
echo.
echo   NEXT STEPS
echo   1. If the Hermes desktop app is running, press Ctrl+K and run
echo      "Reload desktop plugins" (a plugin that failed its first load is
echo      not retried by the folder watcher).
echo   2. Look at the bottom-right status bar for a chip that reads
echo      "lock N" (the character for lock, then a number).
echo   3. Click it: every active session lease is listed, with buttons to
echo      release one, only the dead ones, or all of them.
echo.
echo   The backend route is /api/plugins/session-lock/leases . If the dialog
echo   says the backend is unavailable, restart the app once and try again.
echo.
pause
exit /b 0

:nopayload
echo [X] dashboard\ or desktop\ folder missing next to the install\ folder.
echo     Run this from a full checkout / extracted archive of the repo.
pause
exit /b 1

:nohh
echo [X] Could not find Hermes home (looked at HERMES_HOME, %%LOCALAPPDATA%%\hermes,
echo     %%USERPROFILE%%\.hermes - none had config.yaml).
echo     If Hermes lives elsewhere, close this window and run:
echo         set HERMES_HOME=D:\path\to\hermes
echo         install\install.bat
pause
exit /b 1

:copyfail
echo [X] Copy failed. Close the Hermes desktop app and re-run this installer.
pause
exit /b 1

:nohermes
echo [X] "hermes" is not on PATH, so the backend half cannot be enabled
echo     automatically. The files are already copied. Run this once in
echo     PowerShell:
echo         hermes config set plugins.enabled '["session-lock"]'
pause
exit /b 1

:enablefail
echo [X] Could not write plugins.enabled. Run this by hand in PowerShell:
echo         hermes config set plugins.enabled '["session-lock"]'
pause
exit /b 1
