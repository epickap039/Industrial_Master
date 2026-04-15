<#
.SYNOPSIS
  Anade el directorio bin de Flutter al PATH de la sesion actual si hace falta.

.DESCRIPTION
  Orden de resolucion:
    1. scripts/local_paths.ps1 (si existe) para definir FLUTTER_ROOT u otras variables.
    2. flutter ya disponible en PATH.
    3. Variable de entorno FLUTTER_ROOT (raiz del SDK, no la carpeta bin).
    4. Rutas habituales en Windows.

  Uso (desde la raiz del repo):
    . .\scripts\Ensure-FlutterPath.ps1
    Ensure-FlutterPath
#>
function Get-FlutterBinPath {
    $candidates = [System.Collections.Generic.List[string]]::new()

    if ($env:FLUTTER_ROOT) {
        $candidates.Add((Join-Path $env:FLUTTER_ROOT 'bin'))
    }

    $candidates.Add('C:\src\flutter\bin')
    $candidates.Add('C:\flutter\bin')
    $candidates.Add((Join-Path $env:LOCALAPPDATA 'flutter\bin'))
    $candidates.Add((Join-Path $env:USERPROFILE 'flutter\bin'))
    $candidates.Add((Join-Path $env:USERPROFILE 'dev\flutter\bin'))
    $candidates.Add((Join-Path $env:USERPROFILE 'source\flutter\bin'))

    foreach ($dir in $candidates) {
        if (-not $dir) { continue }
        $flutterBat = Join-Path $dir 'flutter.bat'
        $flutterExe = Join-Path $dir 'flutter.exe'
        if ((Test-Path -LiteralPath $flutterBat) -or (Test-Path -LiteralPath $flutterExe)) {
            return $dir
        }
    }
    return $null
}

function Ensure-FlutterPath {
    [CmdletBinding()]
    param()

    $localPaths = Join-Path $PSScriptRoot 'local_paths.ps1'
    if (Test-Path -LiteralPath $localPaths) {
        . $localPaths
    }

    $existing = Get-Command flutter -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Verbose "Flutter ya en PATH: $($existing.Source)"
        return $true
    }

    $bin = Get-FlutterBinPath
    if (-not $bin) {
        Write-Error @"
No se encontro Flutter SDK.
- Instala Flutter y anade su carpeta \bin al PATH del sistema, o
- Define FLUTTER_ROOT (raiz del SDK) en variables de entorno, o
- Copia scripts/local_paths.ps1.example a scripts/local_paths.ps1 y define FLUTTER_ROOT alli.
"@
        return $false
    }

    if ($env:PATH -notlike "*${bin}*") {
        $env:PATH = "$bin;$env:PATH"
    }
    Write-Host "Flutter anadido al PATH de esta sesion: $bin"
    return $true
}
