@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM ============================================================================
REM  Empaqueta Windows (.exe + DLLs) + APK + actualizador .bat en UNA carpeta.
REM  Destino local: build\windows\x64\runner\Release\
REM  Asi robocopy /MIR a la red no borra el .bat ni deja fuera el APK.
REM
REM  Uso: ejecutar desde la raiz del repo (doble clic o CMD).
REM  Opcional: set COPIAR_A_RED=1 antes de llamar para espejar a Z:\...
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
echo [1/5] flutter build windows --release
call "%FLUTTER%" build windows --release
if errorlevel 1 goto :fail

echo.
echo [2/5] flutter build apk --release
call "%FLUTTER%" build apk --release
if errorlevel 1 goto :fail

echo.
echo [3/5] Copiando ACTUALIZAR_Y_ABRIR_DESDE_RED.bat al paquete Release...
if not exist "ACTUALIZAR_Y_ABRIR_DESDE_RED.bat" (
  echo [ERROR] Falta ACTUALIZAR_Y_ABRIR_DESDE_RED.bat en la raiz del proyecto.
  goto :fail
)
copy /Y "ACTUALIZAR_Y_ABRIR_DESDE_RED.bat" "%REL%\"
if errorlevel 1 goto :fail

echo.
echo [4/5] Copiando APK al paquete Release...
if not exist "%APK_SRC%" (
  echo [ERROR] No se encontro el APK generado:
  echo         %APK_SRC%
  goto :fail
)
copy /Y "%APK_SRC%" "%APK_DST%"
if errorlevel 1 goto :fail

echo.
echo [5/5] Resumen carpeta Release:
echo        %CD%\%REL%
echo        - industrial_manager_v15_5.exe
echo        - industrial_manager_v15_5-release.apk  ^(Android^)
echo        - ACTUALIZAR_Y_ABRIR_DESDE_RED.bat
echo.

if /I "%COPIAR_A_RED%"=="1" (
  set "DST=Z:\APP DE INGENIERIA\aplicacion"
  if not exist "!DST!\" (
    echo [AVISO] No existe !DST! — no se copia a red. Define COPIAR_A_RED=0 o revisa unidad Z:.
    goto :ok
  )
  echo Espejando a red: !DST!
  robocopy "%REL%" "!DST!" /MIR /R:2 /W:1 /NFL /NDL /NP
  set "RC=!ERRORLEVEL!"
  if !RC! GEQ 8 (
    echo [ERROR] Robocopy fallo con codigo !RC!.
    pause
    exit /b !RC!
  )
  echo OK: Carpeta de red actualizada.
)

:ok
echo Listo.
exit /b 0

:fail
echo [ERROR] Empaquetado interrumpido.
pause
exit /b 1
