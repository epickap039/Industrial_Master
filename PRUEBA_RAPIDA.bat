@echo off
echo ==========================================
echo   INDUSTRIAL MANAGER v15.5 - PRUEBA RAPIDA
echo ==========================================

call MATAR_TODO.bat

echo.
echo [1/2] Iniciando Backend (FastAPI)...
start "BACKEND API (No cerrar)" cmd /k "cd backend && .venv\Scripts\activate && python server.py"

echo.
echo [2/2] Iniciando Frontend (Flutter Windows)...
echo Espere mientras compila y lanza la ventana...
flutter run -d windows
