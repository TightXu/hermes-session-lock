@echo off
setlocal EnableExtensions
title Hermes session-lock plugin uninstaller
echo ============================================================
echo   Hermes "session-lock" plugin  -  uninstaller
echo ============================================================
echo.

set "ROOT=%~dp0.."

set "HH=%HERMES_HOME%"
if not "%HH%"=="" if exist "%HH%\config.yaml" goto :havehh
set "HH="
if exist "%LOCALAPPDATA%\hermes\config.yaml" set "HH=%LOCALAPPDATA%\hermes"
if not "%HH%"=="" goto :havehh
if exist "%USERPROFILE%\.hermes\config.yaml" set "HH=%USERPROFILE%\.hermes"
:havehh
if "%HH%"=="" (
  echo [X] Hermes home not found. Set HERMES_HOME and re-run.
  if not defined SESSION_LOCK_NO_PAUSE pause
  exit /b 1
)

echo Hermes home: %HH%
echo.
echo This removes:
echo   %HH%\plugins\session-lock
echo   %HH%\desktop-plugins\session-lock
echo It also removes session-lock from plugins.enabled.
echo It does NOT touch session data, .env or the active-session registry.
echo.
if not defined SESSION_LOCK_NO_PAUSE (
  choice /C YN /M "Continue"
  if errorlevel 2 exit /b 0
)

echo [1/3] Disabling plugins.enabled...
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\install\setup_config.ps1" -Mode uninstall -HermesHome "%HH%"
if errorlevel 1 echo [WARN] Could not update plugins.enabled; continuing with folder removal.
echo.

echo [2/3] Removing plugin folders...
if exist "%HH%\plugins\session-lock" rd /S /Q "%HH%\plugins\session-lock"
if exist "%HH%\desktop-plugins\session-lock" rd /S /Q "%HH%\desktop-plugins\session-lock"
echo       removed.
echo.

echo [3/3] Done.
echo   Restart Hermes, or press Ctrl+K and run "Reload desktop plugins",
echo   to drop the chip.
echo.
if not defined SESSION_LOCK_NO_PAUSE pause
exit /b 0
