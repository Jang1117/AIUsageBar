# Build AIUsageBar.exe from AIUsageBar.ps1 and write a SHA-256 checksum file.
#
#   powershell -ExecutionPolicy Bypass -File .\Build.ps1   # builds dist\AIUsageBar.exe and dist\SHA256SUMS.txt
#
# The exe is not code-signed. Windows SmartScreen or antivirus may warn about it;
# if you would rather not trust a binary, run the .ps1 directly (see README.md).
param([string]$Version = "1.0.7.0")

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$dist = Join-Path $root "dist"

if (-not (Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue)) {
    Write-Host "Installing ps2exe (current user)..."
    Install-Module ps2exe -Scope CurrentUser -Force
}

New-Item -ItemType Directory -Path $dist -Force | Out-Null
$exe = Join-Path $dist "AIUsageBar.exe"

Invoke-ps2exe -inputFile (Join-Path $root "AIUsageBar.ps1") -outputFile $exe -noConsole -STA `
    -title "AIUsageBar" -product "AIUsageBar" -version $Version

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash.ToLower()
"$hash  AIUsageBar.exe" | Set-Content -LiteralPath (Join-Path $dist "SHA256SUMS.txt") -Encoding ASCII

Write-Host ""
Write-Host "Built:  $exe"
Write-Host "SHA256: $hash"
