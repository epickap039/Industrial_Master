@echo off
echo ==========================================
echo       RECONSTRUCCION TOTAL - CLEAN
echo ==========================================
taskkill /IM industrial_manager.exe /F
echo Limpiando proyecto...
call flutter clean
echo Obteniendo dependencias...
call flutter pub get
echo Compilando para Windows (Release)...
call flutter build windows --release
echo Copiando Scripts actualizados...
xcopy /E /I /Y scripts build\windows\x64\runner\Release\scripts
echo ==========================================
echo        PROCESO TERMINADO - LISTO
echo ==========================================
pause
