@echo off
setlocal
cd /d "%~dp0"

perl "%~dp0fix-mtime.pl" %*
if errorlevel 1 (
    echo.
    pause
    exit /b 1
)
exit /b 0
