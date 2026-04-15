<#
  Analisis rapido del repo: Flutter + sintaxis Python del backend.
  Lint Python con ruff (puede listar mucha deuda): .\scripts\backend_ruff.ps1
#>
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

& "$PSScriptRoot\flutter_analyze.ps1"
$fa = $LASTEXITCODE

Set-Location -LiteralPath (Join-Path $repoRoot 'backend')
python -m compileall -q .
$py = $LASTEXITCODE

if ($fa -ne 0 -or $py -ne 0) {
    Write-Host "Resumen: flutter_analyze=$fa compileall=$py"
    exit 1
}
Write-Host 'dev_analyze: OK (flutter analyze + compileall). Ruff opcional: .\scripts\backend_ruff.ps1'
exit 0
