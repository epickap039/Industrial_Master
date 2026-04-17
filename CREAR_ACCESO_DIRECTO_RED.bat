@echo off
setlocal EnableExtensions EnableDelayedExpansion
REM ============================================================================
REM  Crea o actualiza un acceso directo (.lnk) al .exe en la carpeta de red.
REM  - Resuelve unidad Z / X / Y / W (o config_red_ingenieria.bat).
REM  - Si existe RED_DEPLOY_SUBCARPETA.txt en "aplicacion", apunta a v2, v3...
REM  - Acceso directo por defecto: raiz de la unidad:  X:\Industrial Manager (red).lnk
REM  Opcional: set IM_RED_LNK_NOMBRE=Industrial Manager.lnk
REM ============================================================================

cd /d "%~dp0"

if exist "%~dp0config_red_ingenieria.bat" (
  call "%~dp0config_red_ingenieria.bat"
)

set "IM_RED_APLIC="
if defined IM_RED_APLIC if exist "!IM_RED_APLIC!\" goto :haveBase

for %%L in (Z X Y W V U) do (
  if exist "%%L:\APP DE INGENIERIA\aplicacion\" (
    set "IM_RED_APLIC=%%L:\APP DE INGENIERIA\aplicacion"
    goto :haveBase
  )
)
echo [ERROR] No se encontro APP DE INGENIERIA\aplicacion en unidades Z,X,Y,W,V,U.
echo         Crea config_red_ingenieria.bat con IM_RED_LETRA o IM_RED_APLIC.
pause
exit /b 1

:haveBase
set "EXE_DIR=!IM_RED_APLIC!"
set "SUB="
if exist "!IM_RED_APLIC!\RED_DEPLOY_SUBCARPETA.txt" (
  set /p SUB=<"!IM_RED_APLIC!\RED_DEPLOY_SUBCARPETA.txt"
)
set "SUB=!SUB: =!"
if defined SUB (
  if /i not "!SUB!"=="." if /i not "!SUB!"=="ROOT" (
    set "EXE_DIR=!IM_RED_APLIC!\!SUB!"
  )
)

set "EXE=!EXE_DIR!\industrial_manager_v15_5.exe"
if not exist "!EXE!" (
  echo [ERROR] No existe el ejecutable:
  echo         "!EXE!"
  pause
  exit /b 2
)

for %%I in ("!IM_RED_APLIC!") do set "DRIVE=%%~dI"
if not defined IM_RED_LNK_NOMBRE set "IM_RED_LNK_NOMBRE=Industrial Manager (red).lnk"
set "LNK=!DRIVE!\!IM_RED_LNK_NOMBRE!"

set "PS1=%~dp0tool\red\crear_acceso_red.ps1"
if not exist "!PS1!" set "PS1=%~dp0crear_acceso_red.ps1"
if not exist "!PS1!" (
  echo [ERROR] No se encontro crear_acceso_red.ps1 en tool\red ni junto a este .bat
  pause
  exit /b 4
)

echo Creando acceso directo:
echo   LNK: !LNK!
echo   EXE: !EXE!

powershell -NoProfile -ExecutionPolicy Bypass -File "!PS1!" -Lnk "!LNK!" -Target "!EXE!" -WorkDir "!EXE_DIR!"

if errorlevel 1 (
  echo [ERROR] No se pudo crear el acceso directo.
  pause
  exit /b 3
)

echo OK.
exit /b 0
