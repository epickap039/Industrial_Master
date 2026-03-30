@echo off
cd /d "%~dp0"
if not exist "build\native_assets\windows" mkdir "build\native_assets\windows"
call flutter build windows %*
exit /b %ERRORLEVEL%
