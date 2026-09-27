$ErrorActionPreference = 'Stop'
$uri = 'https://raw.githubusercontent.com/qq541253643-art/tk-news-installer/101aaf5/installer.ps1'
$path = Join-Path $env:TEMP 'tk-news-installer.ps1'
try {
    Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $path
}
catch {
    Write-Host ('[FAIL] Cannot download installer: ' + $_.Exception.Message) -ForegroundColor Red
    [void](Read-Host 'Press Enter to close')
    throw
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path
if ($LASTEXITCODE -ne 0) { throw "Installer failed with exit code $LASTEXITCODE" }
