@echo off
setlocal enabledelayedexpansion

echo.
echo ====================================================
echo [MATAR_TODO] Iniciando limpieza de procesos...
echo ====================================================
echo.

:: Matar procesos Python (backend, server.py)
echo [1/4] Terminando procesos Python...
taskkill /F /IM python.exe /T >nul 2>&1
if errorlevel 0 (
    echo [OK] Procesos Python terminados
) else (
    echo - No hay procesos Python activos
)

:: Matar procesos uvicorn (FastAPI)
echo [2/4] Terminando uvicorn (FastAPI)...
taskkill /F /IM uvicorn.exe /T >nul 2>&1
if errorlevel 0 (
    echo [OK] Uvicorn terminado
) else (
    echo - Uvicorn no estaba activo
)

:: Matar flutter run (proceso de la app)
echo [3/4] Terminando Flutter...
taskkill /F /IM industrial_manager_v15_5.exe /T >nul 2>&1
taskkill /F /IM dart.exe /T >nul 2>&1
if errorlevel 0 (
    echo [OK] Flutter/Dart terminado
) else (
    echo - Flutter no estaba activo
)

:: Liberar puerto 8001 específicamente
echo [4/4] Liberando puerto 8001...
for /f "tokens=5" %%a in ('netstat -aon ^| find ":8001" ^| find "LISTENING"') do (
    taskkill /F /PID %%a /T >nul 2>&1
)
echo [OK] Puerto 8001 liberado

echo.
echo ====================================================
echo [MATAR_TODO] Limpieza completada.
echo Puertos 8001 y 1433 disponibles para usar.
echo ====================================================
echo.

endlocal
