@echo off
setlocal EnableExtensions EnableDelayedExpansion
REM ============================================================================
REM  Compila Windows release, opcionalmente APK, copia scripts a Release y
REM  opcionalmente despliega a la red (DESPLEGAR_A_RED.bat).
REM
REM  Uso: desde la raiz del repo (doble clic o CMD).
REM    set COPIAR_A_RED=1     -> despues del build llama DESPLEGAR_A_RED.bat
REM    set SKIP_APK=1        -> no compila APK (mas rapido)
REM
REM  Flutter: ajusta FLUTTER si no esta en C:\flutter\bin\flutter.bat
REM ============================================================================

cd /d "%~dp0"

set "FLUTTER=C:\flutter\bin\flutter.bat"
if not exist "%FLUTTER%" (
  echo [ERROR] No se encontro Flutter en: %FLUTTER%
  echo         Ajusta FLUTTER en este .bat o anade flutter al PATH.
  pause
  exit /b 1
)

set "REL=build\windows\x64\runner\Release"
set "APK_SRC=build\app\outputs\flutter-apk\app-release.apk"
set "APK_DST=%REL%\industrial_manager_v15_5-release.apk"

if not exist "build\native_assets\windows" mkdir "build\native_assets\windows"

echo.
echo [1/4] flutter build windows --release
call "%FLUTTER%" build windows --release
if errorlevel 1 goto :fail

if /I not "%SKIP_APK%"=="1" (
  echo.
  echo [2/4] flutter build apk --release
  call "%FLUTTER%" build apk --release
  if errorlevel 1 goto :fail
) else (
  echo.
  echo [2/4] Omitido APK ^(SKIP_APK=1^)
)

echo.
echo [3/4] Copiando scripts al paquete Release...
if not exist "ACTUALIZAR_Y_ABRIR_DESDE_RED.bat" (
  echo [ERROR] Falta ACTUALIZAR_Y_ABRIR_DESDE_RED.bat en la raiz del proyecto.
  goto :fail
)
copy /Y "ACTUALIZAR_Y_ABRIR_DESDE_RED.bat" "%REL%\" >nul
if errorlevel 1 goto :fail

if exist "CREAR_ACCESO_DIRECTO_RED.bat" (
  copy /Y "CREAR_ACCESO_DIRECTO_RED.bat" "%REL%\" >nul
)
if exist "tool\red\crear_acceso_red.ps1" (
  copy /Y "tool\red\crear_acceso_red.ps1" "%REL%\" >nul
)

if /I not "%SKIP_APK%"=="1" (
  echo.
  echo [4/4] Copiando APK al paquete Release...
  if not exist "%APK_SRC%" (
    echo [ERROR] No se encontro el APK generado:
    echo         %APK_SRC%
    goto :fail
  )
  copy /Y "%APK_SRC%" "%APK_DST%" >nul
  if errorlevel 1 goto :fail
) else (
  echo.
  echo [4/4] Sin APK en Release ^(SKIP_APK=1^)
)

echo.
echo Listo carpeta Release:
echo   %CD%\%REL%
echo   - industrial_manager_v15_5.exe
echo   - ACTUALIZAR_Y_ABRIR_DESDE_RED.bat
if exist "%REL%\CREAR_ACCESO_DIRECTO_RED.bat" echo   - CREAR_ACCESO_DIRECTO_RED.bat
if exist "%REL%\crear_acceso_red.ps1" echo   - crear_acceso_red.ps1
if exist "%APK_DST%" echo   - industrial_manager_v15_5-release.apk
echo.

if /I "%COPIAR_A_RED%"=="1" (
  if not exist "%~dp0DESPLEGAR_A_RED.bat" (
    echo [ERROR] Falta DESPLEGAR_A_RED.bat
    goto :fail
  )
  call "%~dp0DESPLEGAR_A_RED.bat"
  if errorlevel 1 goto :fail
)

echo Empaquetado terminado OK.
exit /b 0

:fail
echo [ERROR] Empaquetado interrumpido.
pause
exit /b 1
