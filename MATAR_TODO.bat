@echo off
echo [MATAR_TODO] Deteniendo procesos del sistema...
taskkill /F /IM uvicorn.exe /T 2>nul
taskkill /F /IM python.exe /T 2>nul
taskkill /F /IM industrial_manager_v15_5.exe /T 2>nul
echo [MATAR_TODO] Limpieza completada. Puertos 8001 y 1433 libres (cliente).
