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
if not "%HH%"=="" if exist "%HH%\config.yaml" goto :havehh
set "HH="
if exist "%LOCALAPPDATA%\hermes\config.yaml" set "HH=%LOCALAPPDATA%\hermes"
if not "%HH%"=="" goto :havehh
if exist "%USERPROFILE%\.hermes\config.yaml" set "HH=%USERPROFILE%\.hermes"
:havehh
if "%HH%"=="" goto :nohh
if not exist "%HH%\config.yaml" goto :nohh

echo [1/4] Hermes home : %HH%
echo.

rem ---------- 2. copy the plugin halves (idempotent) ----------
echo [2/4] Copying plugin files...
if not exist "%HH%\plugins" mkdir "%HH%\plugins" 2>nul
if not exist "%HH%\plugins\session-lock" mkdir "%HH%\plugins\session-lock" 2>nul
if not exist "%HH%\plugins\session-lock\dashboard" mkdir "%HH%\plugins\session-lock\dashboard" 2>nul
if not exist "%HH%\desktop-plugins" mkdir "%HH%\desktop-plugins" 2>nul
if not exist "%HH%\desktop-plugins\session-lock" mkdir "%HH%\desktop-plugins\session-lock" 2>nul

if exist "%HH%\plugins\session-lock\dashboard\plugin_api.py" copy /Y "%HH%\plugins\session-lock\dashboard\plugin_api.py" "%HH%\plugins\session-lock\dashboard\plugin_api.py.bak-installer" >nul 2>nul
if exist "%HH%\plugins\session-lock\dashboard\manifest.json" copy /Y "%HH%\plugins\session-lock\dashboard\manifest.json" "%HH%\plugins\session-lock\dashboard\manifest.json.bak-installer" >nul 2>nul
if exist "%HH%\desktop-plugins\session-lock\plugin.js" copy /Y "%HH%\desktop-plugins\session-lock\plugin.js" "%HH%\desktop-plugins\session-lock\plugin.js.bak-installer" >nul 2>nul

copy /Y "%DASH%\plugin_api.py" "%HH%\plugins\session-lock\dashboard\plugin_api.py" >nul || goto :copyfail
copy /Y "%DASH%\manifest.json" "%HH%\plugins\session-lock\dashboard\manifest.json" >nul || goto :copyfail
copy /Y "%DESK%\plugin.js" "%HH%\desktop-plugins\session-lock\plugin.js" >nul || goto :copyfail
if exist "%HH%\plugins\session-lock\dashboard\__pycache__" rd /S /Q "%HH%\plugins\session-lock\dashboard\__pycache__" 2>nul
echo       %HH%\plugins\session-lock\dashboard\plugin_api.py
echo       %HH%\plugins\session-lock\dashboard\manifest.json
echo       %HH%\desktop-plugins\session-lock\plugin.js
echo.

rem ---------- 3. enable the Python half ----------
echo [3/4] Enabling plugins.enabled...
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\install\setup_config.ps1" -Mode install -HermesHome "%HH%"
if errorlevel 1 goto :configfail
echo.

rem ---------- 4. report ----------
echo [4/4] Done.
echo.
where hermes >nul 2>nul
if not errorlevel 1 for /f "delims=" %%V in ('hermes --version 2^>nul') do echo   %%V
echo.
echo   NEXT STEPS
echo   1. If Hermes is running, press Ctrl+K and run "Reload desktop plugins".
echo   2. Look for a "Locks" chip in the status bar.
echo      Click it to see and release session leases.
echo   3. If the chip says the backend is unavailable, restart Hermes once;
echo      a build without the dashboard plugin mount cannot serve /leases.
echo.
echo   This installer only changed plugins.enabled and these two plugin
echo   folders. It did not touch .env, session data or the lease registry.
echo.
if not defined SESSION_LOCK_NO_PAUSE pause
exit /b 0

:nopayload
echo [X] dashboard\ or desktop\ folder missing next to the install\ folder.
echo     Extract the whole archive first, then run install\install.bat.
if not defined SESSION_LOCK_NO_PAUSE pause
exit /b 1

:nohh
echo [X] Could not find Hermes home (looked at HERMES_HOME,
echo     %%LOCALAPPDATA%%\hermes, %%USERPROFILE%%\.hermes - none had config.yaml).
echo     If Hermes lives elsewhere, run this from cmd:
echo         set HERMES_HOME=D:\path\to\hermes
echo         install\install.bat
if not defined SESSION_LOCK_NO_PAUSE pause
exit /b 1

:copyfail
echo [X] Copy failed. Close the Hermes desktop app and re-run.
if not defined SESSION_LOCK_NO_PAUSE pause
exit /b 1

:configfail
echo [X] Could not update plugins.enabled automatically.
echo     Add "session-lock" under plugins.enabled in:
echo         %HH%\config.yaml
echo     A backup of config.yaml is written before any edit.
if not defined SESSION_LOCK_NO_PAUSE pause
exit /b 1
