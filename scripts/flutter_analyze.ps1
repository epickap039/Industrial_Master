$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Ensure-FlutterPath.ps1"
if (-not (Ensure-FlutterPath)) {
    exit 1
}
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $repoRoot
& flutter analyze @args
exit $LASTEXITCODE
