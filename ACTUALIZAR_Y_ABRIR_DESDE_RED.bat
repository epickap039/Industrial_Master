@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM ============================================================================
REM  Actualiza app local desde carpeta de red y luego la ejecuta.
REM  Origen red:   Z:\APP DE INGENIERIA\aplicacion
REM  Destino local: %USERPROFILE%\Desktop\APP de Ingenieria
REM ============================================================================

set "SRC=Z:\APP DE INGENIERIA\aplicacion"
set "DST=%USERPROFILE%\Desktop\APP de Ingenieria"
set "APP_EXE="

echo.
echo [1/5] Validando carpeta de red...
if not exist "%SRC%\" (
  echo [ERROR] No se encontro la ruta de red:
  echo         "%SRC%"
  echo Verifica conexion VPN/red y unidad Z:
  pause
  exit /b 1
)

echo [2/5] Preparando carpeta local...
if not exist "%DST%\" (
  mkdir "%DST%" >nul 2>&1
  if errorlevel 1 (
    echo [ERROR] No se pudo crear la carpeta local:
    echo         "%DST%"
    pause
    exit /b 1
  )
)

echo [3/5] Detectando ejecutable principal...
for %%F in ("%SRC%\*.exe") do (
  if /I not "%%~nxF"=="unins000.exe" (
    set "APP_EXE=%%~nxF"
    goto :gotExe
  )
)
:gotExe
if not defined APP_EXE (
  set "APP_EXE=industrial_manager_v15_5.exe"
)
echo         Ejecutable: %APP_EXE%

echo [4/6] Cerrando app local si esta abierta...
taskkill /IM "%APP_EXE%" /F >nul 2>&1
timeout /t 1 >nul

echo [5/6] Copiando actualizacion (puede tardar unos segundos)...
REM /MIR refleja la carpeta de red y elimina en destino solo archivos viejos
REM de la app que ya no existen en origen.
REM Codigos de salida validos de robocopy: 0 a 7.
robocopy "%SRC%" "%DST%" /MIR /R:2 /W:1 /NFL /NDL /NP >nul
set "RC=%ERRORLEVEL%"
if %RC% GEQ 8 (
  echo [ERROR] Robocopy fallo con codigo %RC%.
  pause
  exit /b %RC%
)

echo [6/6] Abriendo aplicacion local...
if exist "%DST%\%APP_EXE%" (
  start "" "%DST%\%APP_EXE%"
  echo OK: App iniciada desde:
  echo     "%DST%\%APP_EXE%"
  exit /b 0
)

REM Fallback: intenta abrir el primer exe disponible en destino.
for %%F in ("%DST%\*.exe") do (
  if /I not "%%~nxF"=="unins000.exe" (
    start "" "%%~fF"
    echo OK: App iniciada desde:
    echo     "%%~fF"
    exit /b 0
  )
)

echo [ERROR] No se encontro un ejecutable en:
echo         "%DST%"
pause
exit /b 2
