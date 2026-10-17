# Add AIUsageBar to Windows startup
$startupDir = [System.IO.Path]::Combine($env:APPDATA, "Microsoft\Windows\Start Menu\Programs\Startup")
$shortcutPath = Join-Path $startupDir "AIUsageBar.lnk"
# Build.ps1 writes dist\AIUsageBar.exe; a prebuilt exe may sit next to this script
$exePath = @((Join-Path $PSScriptRoot "AIUsageBar.exe"), (Join-Path $PSScriptRoot "dist\AIUsageBar.exe")) |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $exePath) {
    throw "Build AIUsageBar.exe first (.\Build.ps1) before enabling startup. See README.md."
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $exePath
$shortcut.Arguments = ""
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.Description = "AIUsageBar - AI Usage Monitor"
$shortcut.Save()

Write-Host "AIUsageBar added to Windows startup: $shortcutPath"
Write-Host "It will start automatically on next login."
