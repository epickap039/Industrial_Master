@echo off
setlocal EnableExtensions EnableDelayedExpansion
REM ============================================================================
REM  Copia build\windows\x64\runner\Release a la carpeta de red SIN /MIR
REM  (no borra certificados, imagenes u otros archivos extra en destino).
REM
REM  1) Intenta copiar a:  <unidad>:\APP DE INGENIERIA\aplicacion
REM  2) Si robocopy falla (p. ej. .exe en uso), crea aplicacion\v2, v3...
REM  3) Escribe RED_DEPLOY_SUBCARPETA.txt en "aplicacion" (v2 o vacio=raiz)
REM  4) Llama a CREAR_ACCESO_DIRECTO_RED.bat si existe en la raiz del repo
REM
REM  Uso (desde raiz del repo):
REM    DESPLEGAR_A_RED.bat
REM    DESPLEGAR_A_RED.bat "ruta\alternativa\Release"
REM ============================================================================

cd /d "%~dp0"

set "REL=%~1"
if not defined REL set "REL=build\windows\x64\runner\Release"

if not exist "%REL%\industrial_manager_v15_5.exe" (
  echo [ERROR] No existe Release con el .exe:
  echo         "%CD%\%REL%"
  pause
  exit /b 1
)

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

echo [ERROR] No se encontro APP DE INGENIERIA\aplicacion en Z,X,Y,W...
echo         Crea config_red_ingenieria.bat (ver .example) con IM_RED_LETRA o IM_RED_APLIC.
pause
exit /b 1

:haveBase
echo.
echo Origen Release:
echo   %CD%\%REL%
echo Destino red:
echo   !IM_RED_APLIC!
echo.

REM /E copia arbol; sin /MIR no se eliminan archivos extra en destino.
set "DST=!IM_RED_APLIC!"
robocopy "%REL%" "!DST!" /E /R:2 /W:2 /NFL /NDL /NP
set "RC=!ERRORLEVEL!"
echo Robocopy codigo de salida: !RC!

if !RC! LSS 8 (
  if exist "!IM_RED_APLIC!\RED_DEPLOY_SUBCARPETA.txt" del /q "!IM_RED_APLIC!\RED_DEPLOY_SUBCARPETA.txt" >nul 2>&1
  echo [OK] Despliegue en raiz de aplicacion. Sin puntero v2 ^(archivo RED_DEPLOY eliminado si existia^).
  goto :shortcut
)

echo [AVISO] Robocopy indico error !RC! ^(a veces .exe bloqueado^). Probando v2, v3...
for /l %%n in (2,1,50) do (
  if not exist "!IM_RED_APLIC!\v%%n\" (
    set "VDST=!IM_RED_APLIC!\v%%n"
    mkdir "!VDST!" >nul 2>&1
    robocopy "%REL%" "!VDST!" /E /R:2 /W:2 /NFL /NDL /NP
    set "RC2=!ERRORLEVEL!"
    echo Robocopy a v%%n codigo: !RC2!
    if !RC2! LSS 8 (
      echo v%%n> "!IM_RED_APLIC!\RED_DEPLOY_SUBCARPETA.txt"
      echo [OK] Copiado en: !VDST!
      echo     Puntero: RED_DEPLOY_SUBCARPETA.txt = v%%n
      goto :shortcut
    )
    echo [ERROR] Fallo copia a v%%n con codigo !RC2!.
    pause
    exit /b !RC2!
  )
)
echo [ERROR] No hay carpeta v2..v50 libre bajo aplicacion.
pause
exit /b 21

:shortcut
if exist "%~dp0CREAR_ACCESO_DIRECTO_RED.bat" (
  echo.
  echo Actualizando acceso directo en raiz de unidad...
  call "%~dp0CREAR_ACCESO_DIRECTO_RED.bat"
)
exit /b 0
