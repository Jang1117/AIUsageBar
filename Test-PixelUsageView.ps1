$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'AIUsageBar.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Source parse errors' }
# Load only drawing helpers and embedded artwork; no startup or account access.
foreach ($statement in $ast.EndBlock.Statements) {
    if (($statement -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
         ($statement.Name -match 'Pixel' -or $statement.Name -in @('Format-TimeRemaining','Get-TrayIcon'))) -or
        ($statement -is [System.Management.Automation.Language.AssignmentStatementAst] -and
         $statement.Left.Extent.Text -in @('$script:PixelGlyphs', '$script:PixelIconData'))) {
        Invoke-Expression $statement.Extent.Text
    }
}
$script:PixelClaudeUsage = @{ FiveHour = @{Utilization=4;ResetsAt=([DateTimeOffset]::UtcNow.AddHours(4).AddMinutes(7).ToUnixTimeSeconds())}; SevenDay = @{Utilization=85;ResetsAt=([DateTimeOffset]::UtcNow.AddDays(3).AddHours(21).AddSeconds(30).ToUnixTimeSeconds())} }
$script:PixelCodexUsage = @{Windows=@(@{UsedPercent=2;ResetAt=([DateTimeOffset]::UtcNow.AddHours(4).AddMinutes(7).ToUnixTimeSeconds());WindowSecs=18000}, @{UsedPercent=71;ResetAt=([DateTimeOffset]::UtcNow.AddDays(3).AddHours(21).AddSeconds(30).ToUnixTimeSeconds());WindowSecs=604800})}
$script:PixelAntigravityUsage = @{Groups=@(
    @{FiveHour=@{UsedPercent=0;ResetTime=([DateTimeOffset]::UtcNow.AddHours(4).AddMinutes(7).ToUnixTimeSeconds())};Weekly=@{UsedPercent=95.1;ResetTime=([DateTimeOffset]::UtcNow.AddDays(3).AddHours(21).AddSeconds(30).ToUnixTimeSeconds())}},
    @{FiveHour=@{UsedPercent=3;ResetTime=([DateTimeOffset]::UtcNow.AddHours(4).AddMinutes(7).ToUnixTimeSeconds())};Weekly=@{UsedPercent=97.2;ResetTime=([DateTimeOffset]::UtcNow.AddDays(3).AddHours(21).AddSeconds(30).ToUnixTimeSeconds())}}
)}
$hostItem = Initialize-PixelUsageView
try {
    $persistentImage = $script:PixelPicture.Image
    $before = $persistentImage.Clone()
    $rows = @(Get-PixelUsageRows '5H')
    if ($rows[0].Used -ne 4 -or $rows[1].Used -ne 2 -or $rows[2].Used -ne 3) { throw '5H selection failed' }
    $rows = @(Get-PixelUsageRows 'WK')
    if ($rows[0].Used -ne 85 -or $rows[1].Used -ne 71 -or $rows[2].Used -ne 97.2) { throw 'Weekly selection failed' }
    # Verify descending sort when group 0 is larger than group 1 (Hashtable key sorting)
    $script:PixelAntigravityUsage = @{Groups=@(
        @{FiveHour=@{UsedPercent=5.2;ResetTime=12345};Weekly=@{UsedPercent=1.6;ResetTime=12345}},
        @{FiveHour=@{UsedPercent=0;ResetTime=67890};Weekly=@{UsedPercent=0;ResetTime=67890}}
    )}
    $testRows = @(Get-PixelUsageRows '5H')
    if ($testRows[2].Used -ne 5.2) { throw 'Antigravity group 0 descending sort failed' }
    $testRowsWk = @(Get-PixelUsageRows 'WK')
    if ($testRowsWk[2].Used -ne 1.6) { throw 'Antigravity group 0 weekly descending sort failed' }
    # Restore original fixture
    $script:PixelAntigravityUsage = @{Groups=@(
        @{FiveHour=@{UsedPercent=0;ResetTime=([DateTimeOffset]::UtcNow.AddHours(4).AddMinutes(7).ToUnixTimeSeconds())};Weekly=@{UsedPercent=95.1;ResetTime=([DateTimeOffset]::UtcNow.AddDays(3).AddHours(21).AddSeconds(30).ToUnixTimeSeconds())}},
        @{FiveHour=@{UsedPercent=3;ResetTime=([DateTimeOffset]::UtcNow.AddHours(4).AddMinutes(7).ToUnixTimeSeconds())};Weekly=@{UsedPercent=97.2;ResetTime=([DateTimeOffset]::UtcNow.AddDays(3).AddHours(21).AddSeconds(30).ToUnixTimeSeconds())}}
    )}
    foreach ($period in @('5H','WK')) {
        $script:PixelPeriod = $period
        Update-PixelUsageFrame
        $script:PixelPicture.Image.Save((Join-Path $PSScriptRoot "experiments\pixel-menu-$period.png"))
    }
    if (-not [object]::ReferenceEquals($persistentImage, $script:PixelPicture.Image)) { throw 'Update replaced the entire image' }
    if ($script:PixelRowKeys.Count -ne 6) { throw 'All six quota readings must be visible together' }
    $script:PixelClaudeUsage.FiveHour.Utilization = 33
    Update-PixelUsageFrame
    $script:PixelPicture.Image.Save((Join-Path $PSScriptRoot 'experiments\digital-terminal.png'))
    for ($y = 0; $y -lt 352; $y++) {
        for ($x = 0; $x -lt 54; $x++) {
            if ($before.GetPixel($x,$y) -ne $persistentImage.GetPixel($x,$y)) { throw 'Static logo/background changed during update' }
        }
    }
    for ($y=99; $y -lt 124; $y++) {
        for ($x=56; $x -lt 404; $x++) {
            if ($before.GetPixel($x,$y) -ne $persistentImage.GetPixel($x,$y)) { throw 'Changing 5H altered the weekly row' }
        }
    }
    $before.Dispose()
    foreach ($providerIndex in 0..2) {
        foreach ($period in @('5H','WK')) {
            $hitY = 40 + $providerIndex*102 + $(if ($period -eq '5H') { 42 } else { 71 })
            $hit = Get-PixelQuotaHit 100 $hitY
            if ($hit.Provider -ne @('Claude','Codex','Antigravity')[$providerIndex] -or $hit.Period -ne $period) { throw 'Wrong quota click mapping' }
        }
    }
    foreach ($hitY in @(15,50,97,140,240,350)) {
        if ($null -ne (Get-PixelQuotaHit 100 $hitY)) { throw 'Header or gap selected a quota' }
    }
    $script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $selectionDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $selectionDirectory | Out-Null
    $script:SelectionFile = Join-Path $selectionDirectory 'selection.txt'
    try {
        function Update-Usage { throw 'A selection must never poll providers' }
        Set-PixelQuotaSelection 'Claude' '5H'
        if ((Get-PixelTrayReading).Used -ne 33) { throw 'Claude 5H tray value incorrect' }
        Set-PixelQuotaSelection 'Claude' 'WK'
        if ((Get-PixelTrayReading).Used -ne 85) { throw 'Claude weekly tray value incorrect' }
        if ($script:NotifyIcon.Text -notmatch 'Claude WK: 85%') { throw 'Selected quota tooltip incorrect' }
        if ((Get-Content -LiteralPath $script:SelectionFile) -ne 'Claude|WK') { throw 'Quota selection not persisted' }
        Set-PixelQuotaSelection 'Claude' 'WK'
        if ($script:SelectedProvider -or (Test-Path -LiteralPath $script:SelectionFile)) { throw 'Repeat click did not clear selection' }
        if ((Get-PixelTrayReading).Used -ne 97.2) { throw 'All-quotas fallback incorrect' }
        $script:SelectedProvider = 'Codex'; $script:SelectedPeriod = '5H'
        $savedCodex = $script:PixelCodexUsage
        $script:PixelCodexUsage = $null
        Update-PixelTrayIcon
        if ($script:NotifyIcon.Text -notmatch 'Codex 5H: No data') { throw 'Missing selected quota fell back to another window' }
        $script:PixelCodexUsage = $savedCodex
        $script:SelectedProvider = $null; $script:SelectedPeriod = $null
        if (@(0,50,75,85,95 | ForEach-Object { (Get-PixelUsageColor $_).ToArgb() } | Select-Object -Unique).Count -ne 5) { throw 'Status colors are not distinct' }
        $reset = [DateTimeOffset]::UtcNow.AddDays(3).AddHours(21).AddSeconds(30).ToUnixTimeSeconds()
        if ((Format-PixelReset $reset) -ne '3d 21h') { throw 'Reset duration spacing incorrect' }
        Set-PixelQuotaSelection 'Claude' 'WK'
        $script:PixelPicture.Image.Save((Join-Path $PSScriptRoot 'experiments\terminal-selection.png'))
        $script:SelectedProvider = $null; $script:SelectedPeriod = $null
    } finally {
        $script:NotifyIcon.Icon.Dispose(); $script:NotifyIcon.Dispose(); $script:NotifyIcon = $null
        if (Test-Path -LiteralPath $script:SelectionFile) { Remove-Item -LiteralPath $script:SelectionFile }
        Remove-Item -LiteralPath $selectionDirectory
    }
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    Set-PixelMenuAppearance $menu
    $menu.Items.Add($hostItem) | Out-Null
    $menu.Items.Add('Refresh Now') | Out-Null
    $menu.Items.Add('Open Log') | Out-Null
    $menu.Items.Add('Exit') | Out-Null
    Resize-PixelPopup $menu
    $menu.PerformLayout()
    if ($hostItem.Bounds.Left -ne ($menu.Width-$hostItem.Bounds.Right)) { throw "Popup horizontal margins differ: menu=$($menu.Size), canvas=$($hostItem.Bounds)" }
    if ($menu.Width -gt ($script:PixelPicture.Width+20)) { throw 'Popup has extra horizontal space' }
    if (-not $menu.AutoClose) { throw 'Outside-click dismissal disabled' }
    foreach ($area in @([System.Drawing.Rectangle]::new(0,0,1920,1040), [System.Drawing.Rectangle]::new(-1920,0,1920,1080))) {
        $location = Get-PixelPopupLocation $area $menu.Size
        if ($location.X+$menu.Width -ne $area.Right -or $location.Y+$menu.Height -ne $area.Bottom) { throw 'Popup not anchored at monitor bottom right' }
    }
    if ($ast.Extent.Text -match 'Add_DoubleClick') { throw 'Double-click popup handler still present' }
    if ($ast.Extent.Text -match 'Add_Opened|\$menu\.Location\s*=') { throw 'Popup is repositioned after opening' }
    $fakeMenu = [pscustomobject]@{Size=[System.Drawing.Size]::new(436,436);Handle=[IntPtr]::Zero;ShownAt=$null;ShowCount=0}
    $fakeMenu | Add-Member ScriptMethod Show { param($location) $this.ShownAt=$location; $this.ShowCount++ }
    $fakeMenu | Add-Member ScriptMethod Focus { return $true }
    $originalResize = ${function:Resize-PixelPopup}
    try {
        function Resize-PixelPopup { param($Menu) }
        Show-PixelPopup $fakeMenu ([System.Drawing.Rectangle]::new(0,0,1920,1040))
        if ($fakeMenu.ShowCount -ne 1 -or $fakeMenu.ShownAt.X -ne 1484 -or $fakeMenu.ShownAt.Y -ne 604) { throw 'Popup first Show is not at final bottom-right position' }
    } finally { ${function:Resize-PixelPopup} = $originalResize }
    Initialize-PixelPopupNative
    if (-not ('AIUsageBar.PopupNative' -as [type])) { throw 'Popup activation helper unavailable' }
    $beforeStyle = [AIUsageBar.PopupNative]::GetWindowLongW($menu.Handle,-20)
    [AIUsageBar.PopupNative]::SetWindowLongW($menu.Handle,-20,(($beforeStyle -bor 0x40000) -band (-bnot 0x80))) | Out-Null
    Set-PixelPopupToolWindow $menu
    $popupStyle = [AIUsageBar.PopupNative]::GetWindowLongW($menu.Handle,-20)
    if (($popupStyle -band 0x80) -eq 0 -or ($popupStyle -band 0x40000) -ne 0) { throw 'Popup can appear as an application on the taskbar' }
    $menuImage = New-Object System.Drawing.Bitmap($menu.Width, $menu.Height)
    try {
        $menu.DrawToBitmap($menuImage, [System.Drawing.Rectangle]::new(0,0,$menu.Width,$menu.Height))
        $menuImage.Save((Join-Path $PSScriptRoot 'experiments\pixel-menu-container.png'))
        for ($y = 3; $y -lt 350; $y++) {
            $edge = $menuImage.GetPixel(($menu.Width - 3), $y)
            if ($edge.R -gt 100 -or $edge.G -gt 100 -or $edge.B -gt 100) { throw 'Light gutter at right edge' }
        }
    } finally { $menuImage.Dispose(); $menu.Items.Remove($hostItem); $menu.Dispose() }
    $script:PixelCodexUsage = @{Windows=@(@{UsedPercent=89;ResetAt=([DateTimeOffset]::UtcNow.AddDays(3).AddHours(21).AddSeconds(30).ToUnixTimeSeconds());WindowSecs=604800})}
    $rows = @(Get-PixelUsageRows '5H')
    if ($null -ne $rows[1].Used) { throw 'Weekly quota was incorrectly shown as 5H' }
    $script:PixelCodexUsage = @{Windows=@(@{Name='Primary';UsedPercent=100;WindowSecs=86400})}
    $rows = @(Get-PixelUsageRows '5H')
    if ($rows[1].Used -ne 100 -or $rows[1].DisplayPeriod -ne '1D') { throw 'Nonstandard primary quota disappeared or was mislabeled' }
    $rows = @(Get-PixelUsageRows 'WK')
    if ($null -ne $rows[1].Used) { throw 'Missing weekly quota fabricated' }
    $script:SelectedProvider = 'Codex'; $script:SelectedPeriod = '5H'
    if ((Get-PixelTrayReading).Used -ne 100) { throw 'Nonstandard quota missing from tray' }
    $script:SelectedProvider = $null; $script:SelectedPeriod = $null
    $script:PixelCodexUsage = @{Windows=@(@{Name='Primary';UsedPercent=100})}
    $rows = @(Get-PixelUsageRows '5H')
    if ($rows[1].Used -ne 100 -or $rows[1].DisplayPeriod -ne 'PRI') { throw 'Primary quota with unknown duration disappeared' }
    Update-PixelUsageFrame
    $script:PixelClaudeUsage = $null
    $script:PixelCodexUsage = $null
    $script:PixelAntigravityUsage = $null
    foreach ($period in @('5H','WK')) {
        $rows = @(Get-PixelUsageRows $period)
        if (@($rows | Where-Object { $null -ne $_.Used }).Count) { throw 'Unknown usage became zero' }
        $script:PixelPeriod = $period
        Update-PixelUsageFrame
    }
    Write-Host 'Terminal tests passed: six simultaneous readings, independent quota updates, missing data, persistent image, fixed background, dark right gutter.'
} finally { Stop-PixelUsageView; $hostItem.Dispose() }
