param(
  [Parameter(Mandatory = $true)]
  [string]$PfxPath,

  [Parameter(Mandatory = $true)]
  [string]$PfxPassword,

  [string]$ExePath = "build\windows\x64\runner\Release\industrial_manager_v15_5.exe",

  [string]$TimestampUrl = "http://timestamp.digicert.com"
)

$ErrorActionPreference = "Stop"

function Resolve-SignTool {
  $inPath = Get-Command signtool -ErrorAction SilentlyContinue
  if ($inPath) {
    return $inPath.Source
  }

  $candidates = @(
    "C:\Program Files (x86)\Windows Kits\10\bin\*\x64\signtool.exe",
    "C:\Program Files (x86)\Windows Kits\10\App Certification Kit\signtool.exe"
  )

  foreach ($pattern in $candidates) {
    $found = Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue |
      Sort-Object FullName -Descending |
      Select-Object -First 1
    if ($found) {
      return $found.FullName
    }
  }
  return $null
}

$signTool = Resolve-SignTool
if (-not $signTool) {
  throw "No se encontro signtool.exe. Instala Windows SDK (Signing Tools)."
}

if (-not (Test-Path $PfxPath)) {
  throw "No existe el certificado PFX: $PfxPath"
}

if (-not (Test-Path $ExePath)) {
  throw "No existe el EXE a firmar: $ExePath"
}

Write-Host "[SIGN] Usando SignTool: $signTool"
Write-Host "[SIGN] Firmando: $ExePath"

& $signTool sign `
  /fd SHA256 `
  /f $PfxPath `
  /p $PfxPassword `
  /tr $TimestampUrl `
  /td SHA256 `
  $ExePath

if ($LASTEXITCODE -ne 0) {
  throw "Fallo la firma digital del EXE."
}

Write-Host "[SIGN] Verificando firma..."
& $signTool verify /pa /v $ExePath

if ($LASTEXITCODE -ne 0) {
  Write-Warning "La firma existe, pero la cadena no es de confianza en esta maquina."
  Write-Warning "Si usas certificado autofirmado, instala el .cer en Trusted Root + Trusted Publishers."
  $sig = Get-AuthenticodeSignature $ExePath
  if (-not $sig.SignerCertificate) {
    throw "No se detecto certificado firmante en el EXE."
  }
  Write-Host "[OK] EXE firmado con certificado: $($sig.SignerCertificate.Subject)"
  Write-Host "[INFO] Estado local actual: $($sig.Status)"
  exit 0
}

Write-Host "[OK] EXE firmado y verificado correctamente."
