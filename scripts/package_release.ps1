param(
    [Parameter(Mandatory = $true)]
    [string]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$releaseDir = Join-Path $repoRoot "releases\$Version"
if (!(Test-Path $releaseDir)) {
    New-Item -ItemType Directory -Path $releaseDir | Out-Null
}

$artifacts = @(
    (Join-Path $repoRoot "build\windows\x64\runner\Release\industrial_manager_v15_5.exe"),
    (Join-Path $repoRoot "build\app\outputs\flutter-apk\app-release.apk"),
    (Join-Path $repoRoot "build\app\outputs\apk\release\app-release.apk")
) | Where-Object { Test-Path $_ } | Select-Object -Unique

if ($artifacts.Count -eq 0) {
    throw "No se encontraron artefactos (.exe/.apk) en rutas estándar."
}

$hashLines = @()
foreach ($a in $artifacts) {
    $h = Get-FileHash -Path $a -Algorithm SHA256
    $hashLines += "$($h.Hash)  $(Split-Path $a -Leaf)"
    Copy-Item -Path $a -Destination (Join-Path $releaseDir (Split-Path $a -Leaf)) -Force
}

$hashLines | Set-Content -Path (Join-Path $releaseDir "SHA256SUMS.txt") -Encoding utf8

$changelogPath = Join-Path $releaseDir "CHANGELOG.md"
if (!(Test-Path $changelogPath)) {
    @(
        "# Release $Version",
        "",
        "## Cambios",
        "- TODO: describe brevemente los cambios clave.",
        "",
        "## Verificación",
        "- [ ] Instalar certificado (Windows, si aplica).",
        "- [ ] Validar inicio de sesión.",
        "- [ ] Validar monitoreo, catálogo y ayudas visuales.",
        "- [ ] Validar reporte QA y notas de versión.",
        ""
    ) | Set-Content -Path $changelogPath -Encoding utf8
}

Write-Host "Release preparado en: $releaseDir"
Write-Host "Artefactos copiados: $($artifacts.Count)"
Write-Host "SHA256 generado: SHA256SUMS.txt"
