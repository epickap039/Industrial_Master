@echo off
cd /d "%~dp0"
if not exist "build\native_assets\windows" mkdir "build\native_assets\windows"
call flutter build windows %*
REM Para incluir .bat + APK en la misma carpeta Release (despliegue red): EMPAQUETAR_RELEASE_PARA_RED.bat
exit /b %ERRORLEVEL%
