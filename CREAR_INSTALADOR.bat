@echo off
set VERSION=6.2
set DIST_DIR=DISTRIBUCION_v%VERSION%

echo ==========================================
echo    INDUSTRIAL MASTER - CREADOR DE PACK
echo ==========================================
echo Version: %VERSION%
echo Destino: %DIST_DIR%

if exist %DIST_DIR% (
    echo Limpiando distribucion anterior...
    rd /s /q %DIST_DIR%
)

mkdir %DIST_DIR%
mkdir %DIST_DIR%\scripts

echo [1/4] Copiando Ejecutable y DLLs...
if exist build\windows\x64\runner\Release (
    xcopy /E /Y build\windows\x64\runner\Release\* %DIST_DIR%\
) else (
    echo ERROR: No se encontro carpeta de Release. Ejecute primero 'flutter build windows'.
)

echo [2/4] Copiando Scripts de Backend...
copy scripts\data_bridge.py %DIST_DIR%\scripts\
copy scripts\config.json %DIST_DIR%\scripts\
copy scripts\fix_history.py %DIST_DIR%\scripts\

echo [3/4] Copiando Documentacion...
copy DOCS_PARA_IA\MANUAL_USUARIO.md %DIST_DIR%\

echo [4/4] Generando Nota de Instalacion...
echo INSTALACION INDUSTRIAL MASTER v%VERSION% > %DIST_DIR%\INSTALAME.txt
echo ========================================= >> %DIST_DIR%\INSTALAME.txt
echo 1. Instalar ODBC Driver 17 para SQL Server. >> %DIST_DIR%\INSTALAME.txt
echo 2. Verificar conexion a Red Z: (Planos). >> %DIST_DIR%\INSTALAME.txt
echo 3. Correr industrial_manager.exe. >> %DIST_DIR%\INSTALAME.txt
echo 4. Configurar Servidor: PC08\SQLEXPRESS. >> %DIST_DIR%\INSTALAME.txt

echo ==========================================
echo    PROCESO COMPLETADO CON EXITO
echo ==========================================
pause
