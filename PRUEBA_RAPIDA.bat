@echo off
cd /d "%~dp0"

:: --- CONFIGURACIÓN DE FLUTTER ---
set "FLUTTER_ROOT=C:\flutter"
set "PATH=%FLUTTER_ROOT%\bin;%PATH%"

:: --- LIMPIEZA DE RUTAS ANTIGUAS ---
:: Esto es necesario para eliminar los errores "Type not found" de la cache
call flutter clean
call flutter pub get

:: --- INICIO DE PROCESOS ---
echo [1/2] Iniciando Backend...
:: Entrada FastAPI de este repo: backend\server.py (con venv del proyecto)
start /min cmd /c cd /d "%~dp0backend" ^&^& "%~dp0.venv\Scripts\python.exe" server.py

echo [2/2] Iniciando Frontend...
call flutter run -d windows

pause
