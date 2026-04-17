param(
  [Parameter(Mandatory = $true)][string]$Lnk,
  [Parameter(Mandatory = $true)][string]$Target,
  [Parameter(Mandatory = $true)][string]$WorkDir
)
$w = New-Object -ComObject WScript.Shell
$s = $w.CreateShortcut($Lnk)
$s.TargetPath = $Target
$s.WorkingDirectory = $WorkDir
$s.Description = 'Industrial Manager (red)'
$s.Save()
