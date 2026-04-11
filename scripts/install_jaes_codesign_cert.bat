@echo off
setlocal
cd /d "%~dp0"

REM ------------------------------------------------------------
REM Instala certificado de firma JAES en:
REM  - Trusted Root Certification Authorities (Root)
REM  - Trusted Publishers
REM
REM Uso:
REM   install_jaes_codesign_cert.bat
REM   install_jaes_codesign_cert.bat "C:\ruta\jaes_codesign_epickap.cer"
REM ------------------------------------------------------------

set "CERT_PATH=%~1"
if "%CERT_PATH%"=="" set "CERT_PATH=%~dp0certs\jaes_codesign_epickap.cer"

echo [INFO] Certificado: "%CERT_PATH%"

if not exist "%CERT_PATH%" (
  echo [ERROR] No existe el archivo .cer indicado.
  echo         Copia el certificado y vuelve a intentar.
  exit /b 1
)

REM Validar privilegios de administrador
net session >nul 2>&1
if not "%ERRORLEVEL%"=="0" (
  echo [ERROR] Este script requiere ejecutar como Administrador.
  echo         Clic derecho - Ejecutar como administrador.
  exit /b 1
)

echo [STEP] Instalando en almac^en Root...
certutil -f -addstore "Root" "%CERT_PATH%" >nul
if not "%ERRORLEVEL%"=="0" (
  echo [ERROR] Fallo al instalar certificado en Root.
  exit /b 1
)

echo [STEP] Instalando en almac^en TrustedPublisher...
certutil -f -addstore "TrustedPublisher" "%CERT_PATH%" >nul
if not "%ERRORLEVEL%"=="0" (
  echo [ERROR] Fallo al instalar certificado en TrustedPublisher.
  exit /b 1
)

echo [OK] Certificado instalado correctamente.
echo [INFO] Ya puedes ejecutar el EXE firmado en esta computadora.
exit /b 0
