@echo off
cd /d "%~dp0"

:: --- LIMPIEZA PREVIA DE PROCESOS ---
echo [SETUP] Limpiando procesos anteriores...
call "%~dp0MATAR_TODO.bat"
timeout /t 1 /nobreak

:: --- CONFIGURACIÓN DE FLUTTER ---
set "FLUTTER_ROOT=C:\flutter"
set "PATH=%FLUTTER_ROOT%\bin;%PATH%"

:: --- SANEAMIENTO UTF-8 (evita crash del compilador por archivos UTF-16) ---
if exist "%~dp0backend\utf8_repo_sweep.py" (
  echo [SETUP] Verificando codificacion UTF-8...
  python "%~dp0backend\utf8_repo_sweep.py" >nul 2>&1
)

:: --- LIMPIEZA DE RUTAS ANTIGUAS ---
:: Esto es necesario para eliminar los errores "Type not found" de la cache
call flutter clean
call flutter pub get

:: --- INICIO DE PROCESOS ---
echo [1/2] Iniciando Backend (ventana independiente)...
:: Entrada FastAPI de este repo: backend\server.py (con venv del proyecto)
:: Usa 'start' sin /min para ver la ventana del servidor
start "Backend - Industrial Manager v15.5" cmd /k cd /d "%~dp0backend" ^&^& echo Backend iniciando... ^&^& "%~dp0.venv\Scripts\python.exe" server.py

timeout /t 3 /nobreak
echo [2/2] Iniciando Frontend...
call flutter run -d windows

pause
