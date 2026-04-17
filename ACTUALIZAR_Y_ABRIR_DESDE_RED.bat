@echo off
setlocal EnableExtensions EnableDelayedExpansion
REM ============================================================================
REM  Copia la app desde la carpeta de red al escritorio local y la abre.
REM
REM  - Busca la carpeta en Z, X, Y, W, V, U:  \APP DE INGENIERIA\aplicacion
REM  - Opcional: config_red_ingenieria.bat en esta misma carpeta (repo o Release)
REM    con IM_RED_LETRA o IM_RED_APLIC.
REM  - Si en "aplicacion" existe RED_DEPLOY_SUBCARPETA.txt con v2, v3..., copia
REM    desde esa subcarpeta (despliegue alternativo cuando el .exe raiz esta en uso).
REM
REM  Destino local: %USERPROFILE%\Desktop\APP de Ingenieria
REM ============================================================================

set "DST=%USERPROFILE%\Desktop\APP de Ingenieria"
set "APP_EXE="

cd /d "%~dp0"
if exist "%~dp0config_red_ingenieria.bat" (
  call "%~dp0config_red_ingenieria.bat"
)

set "IM_RED_APLIC="
if defined IM_RED_APLIC if exist "!IM_RED_APLIC!\" goto :haveBase

if defined IM_RED_LETRA (
  set "IM_RED_APLIC=!IM_RED_LETRA!:\APP DE INGENIERIA\aplicacion"
  if exist "!IM_RED_APLIC!\" goto :haveBase
)

for %%L in (Z X Y W V U) do (
  if exist "%%L:\APP DE INGENIERIA\aplicacion\" (
    set "IM_RED_APLIC=%%L:\APP DE INGENIERIA\aplicacion"
    goto :haveBase
  )
)

echo [ERROR] No se encontro la carpeta de red:
echo         APP DE INGENIERIA\aplicacion
echo Prueba VPN / unidad de red o crea config_red_ingenieria.bat
echo ^(copia config_red_ingenieria.bat.example^).
pause
exit /b 1

:haveBase
set "SRC=!IM_RED_APLIC!"
set "SUB="
if exist "!IM_RED_APLIC!\RED_DEPLOY_SUBCARPETA.txt" (
  set /p SUB=<"!IM_RED_APLIC!\RED_DEPLOY_SUBCARPETA.txt"
)
set "SUB=!SUB: =!"
if defined SUB (
  if /i not "!SUB!"=="." if /i not "!SUB!"=="ROOT" (
    set "SRC=!IM_RED_APLIC!\!SUB!"
  )
)

echo.
echo [1/5] Origen red:
echo       "!SRC!"
if not exist "!SRC!\" (
  echo [ERROR] Ruta inexistente ^(revisa RED_DEPLOY_SUBCARPETA.txt^).
  pause
  exit /b 1
)

echo [2/5] Preparando carpeta local...
if not exist "%DST%\" (
  mkdir "%DST%" >nul 2>&1
  if errorlevel 1 (
    echo [ERROR] No se pudo crear: "%DST%"
    pause
    exit /b 1
  )
)

echo [3/5] Detectando ejecutable principal...
for %%F in ("!SRC!\*.exe") do (
  if /I not "%%~nxF"=="unins000.exe" (
    set "APP_EXE=%%~nxF"
    goto :gotExe
  )
)
:gotExe
if not defined APP_EXE (
  set "APP_EXE=industrial_manager_v15_5.exe"
)
echo         Ejecutable: !APP_EXE!

echo [4/6] Cerrando app local si esta abierta...
taskkill /IM "!APP_EXE!" /F >nul 2>&1
timeout /t 1 >nul

echo [5/6] Copiando desde red ^(/MIR refleja solo esta carpeta de origen^)...
robocopy "!SRC!" "%DST%" /MIR /R:2 /W:2 /NFL /NDL /NP
set "RC=!ERRORLEVEL!"
if !RC! GEQ 8 (
  echo [ERROR] Robocopy fallo con codigo !RC!.
  pause
  exit /b !RC!
)

echo [6/6] Abriendo aplicacion local...
if exist "%DST%\!APP_EXE!" (
  start "" "%DST%\!APP_EXE!"
  echo OK: !APP_EXE!
  exit /b 0
)

for %%F in ("%DST%\*.exe") do (
  if /I not "%%~nxF"=="unins000.exe" (
    start "" "%%~fF"
    echo OK: %%~nxF
    exit /b 0
  )
)

echo [ERROR] No se encontro .exe en "%DST%"
pause
exit /b 2
