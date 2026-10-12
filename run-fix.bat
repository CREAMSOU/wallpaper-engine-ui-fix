@echo off
setlocal

rem ============================================================
rem  Wallpaper Engine UI fix - one-click launcher
rem  Double-click this file. It re-launches itself elevated,
rem  then runs fix-wallpaper-ui.ps1 as Administrator.
rem ============================================================

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix-wallpaper-ui.ps1" %*

echo.
pause
