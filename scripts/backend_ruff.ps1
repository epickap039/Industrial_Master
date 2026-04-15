$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$backend = Join-Path $repoRoot 'backend'
Set-Location -LiteralPath $backend

$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'SilentlyContinue'
& python -m ruff --version *> $null
$ruffPresent = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = $prevEap

if (-not $ruffPresent) {
    Write-Host 'ruff no encontrado; instalando desde backend/requirements-dev.txt ...'
    python -m pip install -r requirements-dev.txt
    if ($LASTEXITCODE -ne 0) {
        Write-Error 'No se pudo instalar ruff. Ejecuta: python -m pip install -r backend/requirements-dev.txt'
        exit 1
    }
}

& python -m ruff check .
exit $LASTEXITCODE
