@echo off
chcp 65001 >nul 2>&1
REM Mismo entorno que PRUEBA_RAPIDA.bat: Python del .venv en la raiz del proyecto.
REM Si solo ejecutas "python" aqui, puede ser otro interprete sin faster-whisper.

cd /d "%~dp0"
set "VENV_PY=%~dp0..\.venv\Scripts\python.exe"

echo.
echo ===============================================================
echo   Industrial Manager v15.5 - Backend
echo   Puerto: 8001    Host: 0.0.0.0
echo ===============================================================
echo.

if exist "%VENV_PY%" (
  echo [OK] Usando entorno virtual: ..\.venv\Scripts\python.exe
  echo.
  "%VENV_PY%" server.py
) else (
  echo [AVISO] No existe ..\.venv\Scripts\python.exe
  echo         Crea el venv en la raiz del proyecto y instala dependencias:
  echo         cd ..   ^&^& python -m venv .venv
  echo         ..\.venv\Scripts\python.exe -m pip install -r backend\requirements.txt
  echo.
  python server.py
)

pause
