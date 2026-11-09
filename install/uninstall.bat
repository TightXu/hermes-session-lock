@echo off
setlocal EnableExtensions
title Hermes session-lock plugin uninstaller
echo ============================================================
echo   Hermes "session-lock" plugin  -  uninstaller
echo ============================================================
echo.

set "HH=%HERMES_HOME%"
if not "%HH%"=="" goto :havehh
if exist "%LOCALAPPDATA%\hermes\config.yaml" set "HH=%LOCALAPPDATA%\hermes"
if not "%HH%"=="" goto :havehh
if exist "%USERPROFILE%\.hermes\config.yaml" set "HH=%USERPROFILE%\.hermes"
:havehh
if "%HH%"=="" (
  echo [X] Hermes home not found. Set HERMES_HOME and re-run.
  pause & exit /b 1
)

echo Hermes home: %HH%
echo.
echo This removes:
echo   %HH%\plugins\session-lock
echo   %HH%\desktop-plugins\session-lock
echo It does NOT touch session data or the active-session registry.
echo.
choice /C YN /M "Continue"
if errorlevel 2 exit /b 0

if exist "%HH%\plugins\session-lock" rd /S /Q "%HH%\plugins\session-lock"
if exist "%HH%\desktop-plugins\session-lock" rd /S /Q "%HH%\desktop-plugins\session-lock"
echo Removed plugin folders.

where hermes >nul 2>nul
if errorlevel 1 goto :manual
hermes config get plugins.enabled 2>nul | findstr /C:"session-lock" >nul
if errorlevel 1 goto :done
echo.
echo plugins.enabled still lists session-lock (harmless once the folders are gone).
echo Edit plugins.enabled in %HH%\config.yaml if you want it removed.
goto :done

:manual
echo Could not find "hermes" on PATH - check plugins.enabled by hand.

:done
echo.
echo Restart the desktop app (or Ctrl+K - Reload desktop plugins) to drop the chip.
pause
