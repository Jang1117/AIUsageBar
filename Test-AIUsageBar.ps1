# Test harness for AIUsageBar - validates all logic on Windows without GUI
# Runs headlessly: exercises credential reading, JWT parsing, API response parsing,
# time formatting, and icon generation. Exit 0 = all tests pass.

param([switch]$Verbose)

$ErrorActionPreference = "Stop"
$passed = 0
$failed = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$TestName)
    if ($Expected -eq $Actual) {
        if ($Verbose) { Write-Host "  PASS: $TestName" -ForegroundColor Green }
        $script:passed++
    } else {
        Write-Host "  FAIL: $TestName — expected '$Expected', got '$Actual'" -ForegroundColor Red
        $script:failed++
    }
}

function Assert-NotNull {
    param($Value, [string]$TestName)
    if ($null -ne $Value -and $Value -ne "") {
        if ($Verbose) { Write-Host "  PASS: $TestName" -ForegroundColor Green }
        $script:passed++
    } else {
        Write-Host "  FAIL: $TestName — value was null/empty" -ForegroundColor Red
        $script:failed++
    }
}

function Assert-True {
    param([bool]$Condition, [string]$TestName)
    if ($Condition) {
        if ($Verbose) { Write-Host "  PASS: $TestName" -ForegroundColor Green }
        $script:passed++
    } else {
        Write-Host "  FAIL: $TestName" -ForegroundColor Red
        $script:failed++
    }
}

Write-Host "=== AIUsageBar for Windows - Test Suite ===" -ForegroundColor Cyan
Write-Host ""

# --- Test 1: Script loads without error ---
Write-Host "[1] Script parsing..." -ForegroundColor Yellow
try {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        "$PSScriptRoot\AIUsageBar.ps1", [ref]$tokens, [ref]$parseErrors)
    Assert-Equal 0 $parseErrors.Count "Zero parse errors"
    Assert-True ($ast.EndBlock.Statements.Count -gt 0) "Has executable statements"
} catch {
    Write-Host "  FAIL: Script parse threw exception: $_" -ForegroundColor Red
    $failed++
}

# --- Test 2: JWT parsing ---
Write-Host "[2] JWT claim extraction..." -ForegroundColor Yellow

function Get-JwtClaim {
    param([string]$Token, [string]$ClaimName)
    try {
        $parts = $Token.Split('.')
        if ($parts.Length -lt 2) { return $null }
        $payload = $parts[1]
        $mod = $payload.Length % 4
        if ($mod -eq 2) { $payload += "==" }
        elseif ($mod -eq 3) { $payload += "=" }
        $payload = $payload.Replace('-', '+').Replace('_', '/')
        $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
        $claims = $json | ConvertFrom-Json
        return $claims.$ClaimName
    } catch {
        return $null
    }
}

# Test JWT with known payload: {"sub":"user_123","name":"Test User","iat":1516239022}
$testJwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyXzEyMyIsIm5hbWUiOiJUZXN0IFVzZXIiLCJpYXQiOjE1MTYyMzkwMjJ9.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
Assert-Equal "user_123" (Get-JwtClaim -Token $testJwt -ClaimName "sub") "Extract 'sub' claim"
Assert-Equal "Test User" (Get-JwtClaim -Token $testJwt -ClaimName "name") "Extract 'name' claim"
$missing = Get-JwtClaim -Token $testJwt -ClaimName "nonexistent"
Assert-True ($null -eq $missing) "Missing claim returns null"
$badToken = Get-JwtClaim -Token "not.a.jwt.at.all" -ClaimName "sub"
Assert-True ($null -eq $badToken) "Invalid JWT returns null gracefully"

# --- Test 3: Time formatting ---
Write-Host "[3] Time formatting..." -ForegroundColor Yellow

function Format-TimeRemaining {
    param([string]$ResetAt)
    if (-not $ResetAt) { return "?" }
    try {
        $resetTime = [DateTimeOffset]::Parse($ResetAt).UtcDateTime
        $now = [DateTime]::UtcNow
        $diff = $resetTime - $now
        if ($diff.TotalSeconds -le 0) { return "now" }
        if ($diff.TotalHours -lt 1) { return "$([math]::Floor($diff.TotalMinutes))m" }
        if ($diff.TotalDays -lt 1) { return "$([math]::Floor($diff.TotalHours))h$($diff.Minutes)m" }
        return "$([math]::Floor($diff.TotalDays))d$($diff.Hours)h"
    } catch {
        return "?"
    }
}

$pastTime = [DateTime]::UtcNow.AddMinutes(-5).ToString("o")
Assert-Equal "now" (Format-TimeRemaining -ResetAt $pastTime) "Past time shows 'now'"

$futureTime = [DateTime]::UtcNow.AddMinutes(30).ToString("o")
$result = Format-TimeRemaining -ResetAt $futureTime
Assert-True ($result -match '^\d+m$') "30min future shows minutes format ($result)"

$farFuture = [DateTime]::UtcNow.AddHours(3).AddMinutes(15).ToString("o")
$result = Format-TimeRemaining -ResetAt $farFuture
Assert-True ($result -match '^\d+h\d+m$') "3h15m future shows hours format ($result)"

Assert-Equal "?" (Format-TimeRemaining -ResetAt $null) "Null input returns '?'"
Assert-Equal "?" (Format-TimeRemaining -ResetAt "garbage") "Invalid input returns '?'"

# --- Test 4: API response parsing ---
Write-Host "[4] API response parsing..." -ForegroundColor Yellow

$mockClaudeResponse = @{
    five_hour = @{ utilization = 42.5; resets_at = [DateTime]::UtcNow.AddHours(2).ToString("o") }
    seven_day = @{ utilization = 15.2; resets_at = [DateTime]::UtcNow.AddDays(3).ToString("o") }
}

Assert-Equal 42.5 ([math]::Round($mockClaudeResponse.five_hour.utilization, 1)) "Claude 5h parse"
Assert-Equal 15.2 ([math]::Round($mockClaudeResponse.seven_day.utilization, 1)) "Claude 7d parse"
Assert-NotNull $mockClaudeResponse.five_hour.resets_at "Claude reset time present"

$mockCodexResponse = @{
    plan_type = "plus"
    rate_limit = @{
        primary_window = @{ used_percent = 33.7; reset_at = 1716000000; limit_window_seconds = 18000 }
        secondary_window = @{ used_percent = 12.1; reset_at = 1716500000; limit_window_seconds = 604800 }
    }
}

Assert-Equal "plus" $mockCodexResponse.plan_type "Codex plan type parse"
Assert-Equal 33.7 ([math]::Round($mockCodexResponse.rate_limit.primary_window.used_percent, 1)) "Codex primary parse"
Assert-Equal 12.1 ([math]::Round($mockCodexResponse.rate_limit.secondary_window.used_percent, 1)) "Codex weekly parse"

# --- Test 5: Icon generation (requires System.Drawing) ---
Write-Host "[5] Tray icon generation..." -ForegroundColor Yellow

try {
    Add-Type -AssemblyName System.Drawing

    function Get-TrayIcon {
        param([double]$MaxUsage)
        $size = 16
        $bmp = New-Object System.Drawing.Bitmap($size, $size)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

        $color = if ($MaxUsage -lt 50) { [System.Drawing.Color]::FromArgb(82, 208, 23) }
                 elseif ($MaxUsage -lt 75) { [System.Drawing.Color]::FromArgb(255, 215, 0) }
                 elseif ($MaxUsage -lt 90) { [System.Drawing.Color]::FromArgb(255, 140, 0) }
                 else { [System.Drawing.Color]::FromArgb(255, 68, 68) }

        $brush = New-Object System.Drawing.SolidBrush($color)
        $g.FillEllipse($brush, 1, 1, $size - 2, $size - 2)
        $g.Dispose()
        $brush.Dispose()

        $hIcon = $bmp.GetHicon()
        $icon = [System.Drawing.Icon]::FromHandle($hIcon)
        return $icon
    }

    $icon0 = Get-TrayIcon -MaxUsage 0
    Assert-NotNull $icon0 "Green icon (0% usage)"
    $icon0.Dispose()

    $icon60 = Get-TrayIcon -MaxUsage 60
    Assert-NotNull $icon60 "Yellow icon (60% usage)"
    $icon60.Dispose()

    $icon80 = Get-TrayIcon -MaxUsage 80
    Assert-NotNull $icon80 "Orange icon (80% usage)"
    $icon80.Dispose()

    $icon95 = Get-TrayIcon -MaxUsage 95
    Assert-NotNull $icon95 "Red icon (95% usage)"
    $icon95.Dispose()
} catch {
    Write-Host "  SKIP: System.Drawing not available (expected on non-Windows)" -ForegroundColor DarkYellow
}

# --- Test 6: Credential file detection ---
Write-Host "[6] Credential path detection..." -ForegroundColor Yellow

$claudePath = Join-Path $env:USERPROFILE ".claude\.credentials.json"
$codexPath = Join-Path $env:USERPROFILE ".codex\auth.json"

Assert-NotNull $claudePath "Claude credential path resolves"
Assert-NotNull $codexPath "Codex credential path resolves"
Assert-True ($claudePath -like "*\.claude\.credentials.json") "Claude path correct format"
Assert-True ($codexPath -like "*\.codex\auth.json") "Codex path correct format"

# --- Test 7: Claude refresh request compatibility ---
Write-Host "[7] Claude refresh request compatibility..." -ForegroundColor Yellow
$source = Get-Content "$PSScriptRoot\AIUsageBar.ps1" -Raw
Assert-True ($source -match "RefreshUserAgent\s*=\s*'axios/1\.13\.6'") "Refresh uses Claude-compatible HTTP user agent"
Assert-True ($source -match '"User-Agent"\s*=\s*\$c\.RefreshUserAgent') "Refresh request sends the configured user agent"
Assert-True ($source -match '"Accept"\s*=\s*"application/json, text/plain, \*/\*"') "Refresh sends Axios-compatible Accept header"
Assert-True ($source -match '\$body\.scope\s*=\s*\(\$Scopes -join " "\)') "Refresh preserves OAuth scopes"
Assert-True ($source -match 'credentials changed externally; cleared refresh backoff') "External credential refresh clears backoff"
Assert-True ($source -match 'ClaudeMinIntervalSeconds\)\) -DoNotPersist') "Successful poll interval is not persisted as failure backoff"

# --- Test 8: System.Windows.Forms available (tray prerequisite) ---
Write-Host "[8] Windows Forms availability..." -ForegroundColor Yellow
try {
    Add-Type -AssemblyName System.Windows.Forms
    $testIcon = New-Object System.Windows.Forms.NotifyIcon
    Assert-NotNull $testIcon "NotifyIcon instantiation"
    $testIcon.Dispose()

    $testMenu = New-Object System.Windows.Forms.ContextMenuStrip
    Assert-NotNull $testMenu "ContextMenuStrip instantiation"
    $testMenu.Dispose()

    $testTimer = New-Object System.Windows.Forms.Timer
    Assert-NotNull $testTimer "Timer instantiation"
    $testTimer.Dispose()
} catch {
    Write-Host "  SKIP: System.Windows.Forms not available (expected on non-Windows)" -ForegroundColor DarkYellow
}

# --- Test 9: Antigravity quota parsing and executable detection ---
Write-Host "[9] Antigravity quota parsing..." -ForegroundColor Yellow

$source = Get-Content "$PSScriptRoot/AIUsageBar.ps1" -Raw
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
foreach ($definition in $ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    ($node.Name -match 'Antigravity' -or $node.Name -eq 'New-StartupShortcut')
}, $true)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Write-Log { param($Message, $Level) }

$mockAgyJson = @'
{"command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.9176925420761108,"reset_time":"2026-10-11T10:47:22Z"},{"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":0.9597920775413513,"reset_time":"2026-10-05T01:27:57Z"}]},{"name":"Claude and GPT models","buckets":[{"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.4908635914325714,"reset_time":"2026-10-11T11:14:41Z"},{"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1.0,"reset_time":"2026-10-05T01:54:00Z"}]}]}}}
'@

$agyParsed = Parse-AntigravityUsageJson -JsonText $mockAgyJson
Assert-NotNull $agyParsed "Antigravity parsed object not null"
Assert-Equal 2 $agyParsed.Groups.Count "Antigravity parsed two model groups"

$geminiGrp = $agyParsed.Groups | Where-Object { $_.Name -like "*Gemini*" } | Select-Object -First 1
Assert-NotNull $geminiGrp "Gemini group found"
Assert-Equal 4.0 $geminiGrp.FiveHour.UsedPercent "Gemini 5h used percent computed correctly"
Assert-Equal 96.0 $geminiGrp.FiveHour.RemainingPercent "Gemini 5h remaining percent computed correctly"
Assert-Equal "2026-10-05T01:27:57Z" $geminiGrp.FiveHour.ResetTime "Gemini 5h reset time extracted"
Assert-Equal 8.2 $geminiGrp.Weekly.UsedPercent "Gemini weekly used percent computed correctly"

$claudeGrp = $agyParsed.Groups | Where-Object { $_.Name -like "*Claude*" } | Select-Object -First 1
Assert-NotNull $claudeGrp "Claude/GPT group found"
Assert-Equal 0.0 $claudeGrp.FiveHour.UsedPercent "Claude/GPT 5h used percent computed correctly"
Assert-Equal 50.9 $claudeGrp.Weekly.UsedPercent "Claude/GPT weekly used percent computed correctly"
Assert-Equal 50.9 $agyParsed.MaxUsedPercent "Antigravity MaxUsedPercent computed correctly"

# Null / malformed json handling
$badParsed = Parse-AntigravityUsageJson -JsonText "not json"
Assert-True ($null -eq $badParsed) "Invalid JSON handled gracefully"
$emptyParsed = Parse-AntigravityUsageJson -JsonText ""
Assert-True ($null -eq $emptyParsed) "Empty text handled gracefully"

# --- Test 10: Production direct HTTP provider has no process-launch fallback ---
Write-Host "[10] Direct HTTP provider and response formats..." -ForegroundColor Yellow
$providerText = ($ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -match 'Antigravity'
}, $true) | ForEach-Object { $_.Extent.Text }) -join "`n"
$providerTokens = $null
$providerErrors = $null
$providerAst = [System.Management.Automation.Language.Parser]::ParseInput($providerText, [ref]$providerTokens, [ref]$providerErrors)
$externalLaunches = $providerAst.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -in @('Start-Process', 'Start-Job', 'Add-Type', 'cmd', 'cmd.exe', 'agy', 'agy.exe')
}, $true)
Assert-True ($externalLaunches.Count -eq 0 -and $providerText -notmatch 'ProcessStartInfo|Process\]::Start') "Antigravity provider cannot launch a CLI, shell or compiler"
Assert-True ($source -notmatch 'Get-AntigravityPath|AgyProcess') "Legacy CLI discovery and process state are removed"

foreach ($envelope in @('groups', 'response', 'summary')) {
    $payload = '{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","remainingFraction":0,"resetTime":"2026-10-11T10:47:22Z"},{"bucketId":"gemini-weekly","remaining":{"case":"remainingFraction","value":0.25},"resetAt":"2026-10-11T10:47:22Z"},{"bucketId":"disabled-weekly","remainingFraction":0.9,"disabled":true}]}]}'
    if ($envelope -ne 'groups') { $payload = '{"' + $envelope + '":' + $payload + '}' }
    $usage = Parse-AntigravityUsageJson $payload
    Assert-Equal 100 $usage.Groups[0].FiveHour.UsedPercent "$envelope API response preserves zero remaining"
    Assert-Equal 75 $usage.Groups[0].Weekly.UsedPercent "$envelope API response reads nested quota and ignores disabled buckets"
    Assert-Equal '2026-10-11T10:47:22Z' $usage.Groups[0].Weekly.ResetTime "$envelope API response retains reset timestamp"
}
Assert-True ($null -eq (Parse-AntigravityUsageJson '{"groups":[{"name":"Gemini","buckets":[{"id":"5h"}]}]}')) "Missing quota fraction is not misreported as full usage"
Assert-True ($null -eq (Parse-AntigravityUsageJson '{"groups":[{"name":"Gemini","buckets":[{"id":"5h","remainingFraction":"NaN"}]}]}')) "Non-finite quota values are rejected"

# --- Test 11: Credentials decode and runspace polling without subprocesses ---
Write-Host "[11] Native credentials, startup and in-process polling..." -ForegroundColor Yellow
$fakeCredential = '{"token":{"access_token":"test-access","refresh_token":"test-refresh","expiry":"2099-01-01T00:00:00Z"}}'
foreach ($encoding in @([Text.Encoding]::Unicode, [Text.Encoding]::UTF8)) {
    $decoded = ConvertFrom-AntigravityCredentialBlob $encoding.GetBytes($fakeCredential)
    Assert-Equal 'test-access' $decoded.access_token "Credential JSON decoding supports $($encoding.WebName)"
}
$wrappedCredential = 'go-keyring-base64:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($fakeCredential))
$decoded = ConvertFrom-AntigravityCredentialBlob ([Text.Encoding]::Unicode.GetBytes($wrappedCredential))
Assert-Equal 'test-refresh' $decoded.refresh_token "Credential decoding supports the keyring Base64 wrapper"
Assert-True ($null -eq (ConvertFrom-AntigravityCredentialBlob ([Text.Encoding]::UTF8.GetBytes('invalid')))) "Invalid credential payload is rejected"
Initialize-AntigravityCredentialReader
Assert-NotNull ('AIUsageBar.NativeCredential' -as [type]) "Credential reader loads without invoking a compiler"

$testDir = Join-Path ([System.IO.Path]::GetTempPath()) ("aiusagebar-test-" + [guid]::NewGuid())
[void][System.IO.Directory]::CreateDirectory($testDir)
try {
    $script:IsCompiledExe = $false
    $testShortcut = Join-Path $testDir 'startup.lnk'
    $testExe = Join-Path $testDir 'AIUsageBar.exe'
    [System.IO.File]::WriteAllText($testExe, '')
    New-StartupShortcut -ShortcutPath $testShortcut -TargetScriptPath (Join-Path $testDir 'AIUsageBar.ps1')
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($testShortcut)
    Assert-Equal $testExe $shortcut.TargetPath "Source startup targets the GUI executable"
    Assert-Equal '' $shortcut.Arguments "Startup does not invoke a shell"
} finally {
    Get-ChildItem -LiteralPath $testDir -File | Remove-Item -Force
    Remove-Item -LiteralPath $testDir -Force
}

function Set-AntigravityNextAttempt { param([DateTime]$NextAttempt) $script:AgyNextAttempt = $NextAttempt }
$realDirectPoll = ${function:Invoke-AntigravityDirectPoll}
function Invoke-AntigravityDirectPoll {
    return @{ Usage = Parse-AntigravityUsageJson '{"groups":[{"name":"Gemini Models","buckets":[{"id":"weekly","remainingFraction":0.25}]}]}'; AuthMissing = $false }
}
$script:AgyWorker = $null
$script:AgyTokenCache = $null
$script:FastTimer = $null
$script:AntigravityMinIntervalSeconds = 60
$script:AgyFailCount = 0
try {
    Start-AntigravityPoll
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not $script:AgyAsyncResult.IsCompleted -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 10 }
    Assert-True (Check-AntigravityPoll) "In-process worker returns parsed quota"
    Assert-Equal 75 $script:AntigravityUsage.Groups[0].Weekly.UsedPercent "Worker result updates the displayed quota"
    Assert-True ($null -eq $script:AgyWorker) "Completed worker is disposed"
    $lastGood = $script:LastAntigravityUsage
    function Invoke-AntigravityDirectPoll { return @{ Usage = $null; AuthMissing = $false; RetryAfter = 900; Error = 'HTTP 429' } }
    Start-AntigravityPoll
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not $script:AgyAsyncResult.IsCompleted -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 10 }
    Assert-True (-not (Check-AntigravityPoll)) "Failed HTTP poll does not claim fresh usage"
    Assert-True ($script:LastAntigravityUsage -eq $lastGood -and $null -eq $script:AntigravityUsage) "HTTP failure preserves the previous quota as cached data"
    Assert-True ($script:AgyNextAttempt -gt [DateTime]::UtcNow.AddSeconds(800)) "HTTP rate limit preserves Retry-After backoff"
    $script:AgyAuthMissing = $true
    $script:AntigravityUsage = $null
    $script:AgyRefreshRequested = $false
    Update-AntigravityPoll
    Assert-True ($null -eq $script:AgyWorker) "Missing fresh quota does not bypass retry backoff"
    function Invoke-AntigravityDirectPoll {
        param($CachedToken)
        Start-Sleep -Milliseconds 200
        $fraction = if ($CachedToken) { 0.75 } else { 0.1 }
        return @{ Usage = Parse-AntigravityUsageJson ('{"groups":[{"name":"Gemini Models","buckets":[{"id":"weekly","remainingFraction":'+$fraction.ToString([Globalization.CultureInfo]::InvariantCulture)+'}]}]}'); AuthMissing=$false }
    }
    $script:AgyTokenCache = @{access_token='synthetic-old-login'}
    Start-AntigravityPoll
    $oldWorker = $script:AgyWorker
    Request-AntigravityRefresh
    Update-AntigravityPoll
    Assert-True ($script:AgyWorker -eq $oldWorker -and $script:AgyRefreshRequested) "Refresh during an active request is queued without overlapping workers"
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not $script:AgyAsyncResult.IsCompleted -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 10 }
    Update-AntigravityPoll
    Assert-True ($null -ne $script:AgyWorker -and -not $script:AgyRefreshRequested) "Queued manual refresh starts even after old result sets future poll time"
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not $script:AgyAsyncResult.IsCompleted -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 10 }
    Check-AntigravityPoll | Out-Null
    Assert-Equal 90 $script:AntigravityUsage.Groups[0].Weekly.UsedPercent "Manual refresh bypasses cached token and publishes the fresh result"
    $script:AgyRefreshRequested = $false
} finally {
    Stop-AntigravityPoll
    ${function:Invoke-AntigravityDirectPoll} = $realDirectPoll
}


# --- Test 12: Production menu text across refresh, waiting, and failure ---
Write-Host "[12] Weekly reset display and Claude scheduled polling..." -ForegroundColor Yellow
$definition = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Format-TimeRemaining'
}, $true)
. ([scriptblock]::Create($definition.Extent.Text))
$definition = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Update-UsageCore'
}, $true)
$updateText = $definition.Body.Extent.Text
$providerUpdate = [scriptblock]::Create($updateText.Substring(1, $updateText.IndexOf('# --- Antigravity ---') - 1))
function Get-ClaudeOAuthToken { return @{ Token = 'test'; Expired = $false } }
function Fetch-ClaudeUsage { return $script:TestClaudeResponse }
function Get-CodexAuthToken { return @{ Token = 'test' } }
function Fetch-CodexUsage { return $script:TestCodexResponse }
function Set-ClaudeNextAttempt { param($NextAttempt, [switch]$DoNotPersist) $script:ClaudeNextAttempt = $NextAttempt }
foreach ($menu in @('ClaudeMenuItem', 'ClaudeDetailItem', 'CodexMenuItem', 'CodexDetailItem')) {
    Set-Variable -Name $menu -Scope Script -Value ([pscustomobject]@{ Text = '' })
}
$script:ClaudeMinIntervalSeconds = 60
$script:LastClaudeUsage = @{
    FiveHour = @{ Utilization = 4; ResetsAt = [DateTime]::UtcNow.AddHours(4).ToString('o') }
    SevenDay = @{ Utilization = 49; ResetsAt = [DateTime]::UtcNow.AddDays(3).AddHours(9).ToString('o') }
}
$script:TestCodexResponse = @{
    Windows = @(
        @{ UsedPercent = 56; ResetAt = [DateTimeOffset]::UtcNow.AddHours(2).ToUnixTimeSeconds() },
        @{ UsedPercent = 37; ResetAt = [DateTimeOffset]::UtcNow.AddDays(4).ToUnixTimeSeconds() }
    )
}
$script:ClaudeFailCount = 0
$script:ClaudeNextAttempt = [DateTime]::UtcNow.AddMinutes(5)
& $providerUpdate
Assert-True ($script:ClaudeDetailItem.Text -match 'Weekly: 49% \(resets in \d+d\d+h\)$') "Claude scheduled wait preserves weekly countdown without error"
Assert-True ($script:ClaudeMenuItem.Text -notmatch 'stale|retrying|failed') "Claude scheduled wait is not a failure"
Assert-True ($script:CodexDetailItem.Text -match 'Weekly: 37% \(resets in \d+d\d+h\)$') "Codex weekly Unix reset timestamp shows a countdown"

$script:ClaudeNextAttempt = [DateTime]::MinValue
$script:TestClaudeResponse = $null
& $providerUpdate
Assert-True ($script:ClaudeDetailItem.Text -match 'resets in \d+d\d+h.*cached, retrying') "Claude actual failure retains weekly countdown and identifies cached data"
& $providerUpdate
Assert-True ($script:ClaudeDetailItem.Text -match 'resets in \d+d\d+h.*cached, retrying') "Claude backoff preserves countdown and retry status"

$script:ClaudeNextAttempt = [DateTime]::MinValue
$script:TestClaudeResponse = $script:LastClaudeUsage
& $providerUpdate
Assert-Equal 0 $script:ClaudeFailCount "Successful Claude refresh clears failure status"
Assert-True ($script:ClaudeDetailItem.Text -notmatch 'cached|retrying|failed') "Successful Claude refresh restores normal weekly display"
Assert-Equal 'now' (Format-TimeRemaining -ResetAt ([DateTimeOffset]::UtcNow.AddMinutes(-1).ToUnixTimeSeconds())) "Expired Unix reset time shows now"
Assert-Equal '?' (Format-TimeRemaining -ResetAt '999999999999999999999999') "Invalid Unix reset timestamp is handled safely"
# PowerShell 7 hands JSON dates over as [DateTime]; the local-time form must not shift by the UTC offset
$in125 = [DateTime]::UtcNow.AddMinutes(125)
Assert-True ((Format-TimeRemaining -ResetAt $in125) -match '^2h[45]m$') "Reset given as a UTC DateTime is read correctly"
Assert-True ((Format-TimeRemaining -ResetAt $in125.ToLocalTime()) -match '^2h[45]m$') "Reset given as a local DateTime is not shifted by the UTC offset"
Assert-True ((Format-TimeRemaining -ResetAt ([DateTimeOffset]$in125)) -match '^2h[45]m$') "Reset given as a DateTimeOffset is read correctly"
Assert-True ((Format-TimeRemaining -ResetAt $in125.ToString('o')) -match '^2h[45]m$') "Reset given as an ISO string is read correctly"
Assert-Equal '?' (Format-TimeRemaining -ResetAt $null) "Missing reset time shows a question mark"

# --- Test 13: Token lifetime and refresh stay in-process and read-only ---
Write-Host "[13] Antigravity token refresh..." -ForegroundColor Yellow
$realCredentialReader = ${function:Get-AntigravityCredential}
$script:CredentialReads = 0
$script:TokenRequests = 0
$script:TestStoredToken = [pscustomobject]@{
    access_token = 'stored-test'; refresh_token = 'refresh-test'; expiry = '2000-01-01T00:00:00Z'
}
function Get-AntigravityCredential { $script:CredentialReads++; return $script:TestStoredToken }
function Invoke-RestMethod {
    param($Uri, $Method, $ContentType, $Body, $TimeoutSec, $ErrorAction)
    if ($Uri -ne 'https://oauth2.googleapis.com/token' -or $Body.grant_type -ne 'refresh_token') { throw 'Unexpected token request' }
    $script:TokenRequests++
    return @{ access_token = 'refreshed-test'; expires_in = 3600 }
}
$realSecretEnv = $env:AIUSAGEBAR_AGY_OAUTH_CLIENT_SECRET
$env:AIUSAGEBAR_AGY_OAUTH_CLIENT_SECRET = 'test-secret'
try {
    $freshToken = [pscustomobject]@{ access_token = 'cached-test'; refresh_token = 'refresh-test'; expiry = '2099-01-01T00:00:00Z' }
    $resolved = Get-AntigravityAccessToken -CachedToken $freshToken
    Assert-Equal 'cached-test' $resolved.access_token "Unexpired in-memory token is reused"
    Assert-Equal 0 $script:CredentialReads "Valid memory cache avoids redundant credential reads"
    Assert-Equal 0 $script:TokenRequests "Valid memory cache does not refresh OAuth"
    $resolved = Get-AntigravityAccessToken
    Assert-Equal 'refreshed-test' $resolved.access_token "Expired credential is refreshed through Google HTTP"
    Assert-True ([DateTimeOffset]::Parse($resolved.expiry).UtcDateTime -gt [DateTime]::UtcNow.AddMinutes(50)) "Refreshed token expiry is cached correctly"
    Assert-Equal 'stored-test' $script:TestStoredToken.access_token "Refresh does not change the CLI's stored credential"
    $resolved = Get-AntigravityAccessToken -CachedToken $freshToken -ForceRefresh
    Assert-Equal 'refreshed-test' $resolved.access_token "Rejected access token can force a refresh"
    $script:TestStoredToken = $null
    Assert-True ($null -eq (Get-AntigravityAccessToken)) "Missing login returns no token without launching authentication"

    # 갱신용 client_secret이 없으면 소스에 내장된 값이 없으므로 갱신하지 않고 안내한다.
    # 이 PC의 ~/.aiusagebar/config.json 에 영향받지 않도록 빈 임시 홈 폴더에서 확인한다.
    $env:AIUSAGEBAR_AGY_OAUTH_CLIENT_SECRET = ''
    $profileBeforeNoSecret = $env:USERPROFILE
    $env:USERPROFILE = Join-Path ([System.IO.Path]::GetTempPath()) ('aub-empty-' + [guid]::NewGuid().ToString('N'))
    $script:TestStoredToken = [pscustomobject]@{ access_token = 'stored-test'; refresh_token = 'refresh-test'; expiry = '2000-01-01T00:00:00Z' }
    $script:TokenRequests = 0
    $noSecretMessage = $null
    try { Get-AntigravityAccessToken | Out-Null } catch { $noSecretMessage = $_.Exception.Message } finally { $env:USERPROFILE = $profileBeforeNoSecret }
    Assert-True ($noSecretMessage -like 'Antigravity token expired*') "Without a configured client secret, an expired token is not refreshed and the user is told what to do"
    Assert-Equal 0 $script:TokenRequests "No token request is made without a configured client secret"
} finally {
    $env:AIUSAGEBAR_AGY_OAUTH_CLIENT_SECRET = $realSecretEnv
    ${function:Get-AntigravityCredential} = $realCredentialReader
    Remove-Item -LiteralPath function:Invoke-RestMethod
}

# --- Test 14: Claude login file is read-only by default; opt-in refresh rewrites it safely ---
Write-Host "[14] Claude credential safety..." -ForegroundColor Yellow
$claudeFunctions = @('Get-ClaudeOAuthToken', 'Refresh-ClaudeToken', 'Update-ClaudeCredentialFile', 'Get-ClaudeConstants', 'Set-ClaudeNextAttempt')
foreach ($definition in $ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $claudeFunctions
}, $true)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$realProfile = $env:USERPROFILE
$tmpHome = Join-Path ([System.IO.Path]::GetTempPath()) ("aub-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $tmpHome '.claude') -Force | Out-Null
$credPath = Join-Path $tmpHome '.claude\.credentials.json'
$expiredMs = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
$originalCreds = '{"claudeAiOauth":{"accessToken":"old-access","refreshToken":"old-refresh","expiresAt":' + $expiredMs +
    ',"scopes":["user:inference","user:profile"],"subscriptionType":"max"},"otherKey":{"keep":"<me>"}}'
function Reset-ClaudeTestState {
    [System.IO.File]::WriteAllText($credPath, $originalCreds)
    $script:ClaudeRefreshCalls = 0
    $script:ClaudeLoginExpiredLogged = $false
    $script:ClaudeNextAttempt = [DateTime]::MinValue
    $script:ClaudeFailCount = 0
    $script:LastClaudeAccessToken = $null
}
function Invoke-RestMethod {
    param($Uri, $Method, $Headers, $Body, $ContentType, $TimeoutSec, $ErrorAction)
    $script:ClaudeRefreshCalls++
    return @{ access_token = 'new-access'; refresh_token = 'new-refresh'; expires_in = 28800 }
}
$env:USERPROFILE = $tmpHome
try {
    # (a) 기본: 읽기 전용
    Reset-ClaudeTestState
    $script:AllowClaudeTokenRefresh = $false
    $r = Get-ClaudeOAuthToken
    Assert-True ($r.Expired -and $r.LoginExpired) "Expired token in read-only mode is reported as login expired"
    Assert-Equal 0 $script:ClaudeRefreshCalls "Read-only mode never calls the token endpoint"
    Assert-True ([System.IO.File]::ReadAllText($credPath) -ceq $originalCreds) "Read-only mode leaves the login file byte-for-byte unchanged"

    # (b) 켰을 때: 토큰 세 값만 바뀌고 나머지 원문은 그대로
    Reset-ClaudeTestState
    $script:AllowClaudeTokenRefresh = $true
    $r = Get-ClaudeOAuthToken
    Assert-Equal 'new-access' $r.Token "Opt-in refresh returns the new access token"
    Assert-Equal 1 $script:ClaudeRefreshCalls "Opt-in refresh makes exactly one token request"
    $afterText = [System.IO.File]::ReadAllText($credPath)
    $after = $afterText | ConvertFrom-Json
    Assert-Equal 'new-access' $after.claudeAiOauth.accessToken "Refreshed access token is saved"
    Assert-Equal 'new-refresh' $after.claudeAiOauth.refreshToken "Rotated refresh token is saved"
    Assert-True ([int64]$after.claudeAiOauth.expiresAt -gt [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) "New expiry is saved as epoch milliseconds"
    Assert-True ($afterText.Contains('"scopes":["user:inference","user:profile"]') -and $afterText.Contains('"subscriptionType":"max"') -and $afterText.Contains('"otherKey":{"keep":"<me>"}')) "Only the token fields change; other fields keep their original text"
    Assert-True (-not (Test-Path -LiteralPath ($credPath + '.aiusagebar.tmp'))) "No temporary file is left behind after saving"

    # (c) 다른 프로세스(Claude Code)가 먼저 갱신했으면 갱신하지 않는다
    Reset-ClaudeTestState
    [System.IO.File]::WriteAllText($credPath, $originalCreds.Replace('old-refresh', 'rotated-by-claude-code'))
    $res = Refresh-ClaudeToken -RefreshToken 'old-refresh' -CredFile $credPath -Scopes @()
    Assert-True ($null -eq $res -and $script:ClaudeRefreshCalls -eq 0) "Refresh is skipped when another process already rotated the refresh token"

    # (d) 파일 구조가 예상과 다르면 아무것도 쓰지 않는다
    $oddCreds = '{"claudeAiOauth":{"accessToken":"a"}}'
    [System.IO.File]::WriteAllText($credPath, $oddCreds)
    $saved = Update-ClaudeCredentialFile -CredFile $credPath -AccessToken 'x' -RefreshToken 'y' -ExpiresAtMs 1
    Assert-True (-not $saved -and ([System.IO.File]::ReadAllText($credPath) -ceq $oddCreds)) "Unexpected credentials layout is never overwritten"
} finally {
    $env:USERPROFILE = $realProfile
    $script:AllowClaudeTokenRefresh = $false
    Remove-Item -LiteralPath function:Invoke-RestMethod -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmpHome -Recurse -Force -ErrorAction SilentlyContinue
}
Assert-True ($source -match '\$script:AllowClaudeTokenRefresh = \(\$AllowClaudeTokenRefresh\.IsPresent -or \$env:AIUSAGEBAR_CLAUDE_REFRESH -eq ''1''\)') "Claude token refresh is off unless the switch or environment variable is set"

# --- Test 15: Source files are safe to publish ---
Write-Host "[15] Publication hygiene..." -ForegroundColor Yellow
$secretPatterns = @('GOC' + 'SPX-', 'sk-ant-', 'AIza[0-9A-Za-z_-]{20,}', 'ghp_[0-9A-Za-z]{20,}', 'xox[bp]-')
$personalPatterns = @('C:\\Users\\Jang', 'D:\\JangProjects', '\\.sticorp\.co\.kr')
foreach ($name in @('AIUsageBar.ps1', 'README.md', 'Install-Startup.ps1', 'Start-AIUsageBar.vbs', 'Build.ps1')) {
    $path = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $text = Get-Content -LiteralPath $path -Raw
    $hit = @($secretPatterns + $personalPatterns | Where-Object { $text -match $_ })
    Assert-True ($hit.Count -eq 0) "$name contains no embedded secrets or personal paths"
}

# --- Results ---
Write-Host ""
# --- Test 16: Model / group choice on the dashboard (Claude, Codex, Antigravity) ---
Write-Host "[16] Model choice per provider..." -ForegroundColor Yellow
$modelFunctions = @('Get-AntigravityGroupShortName', 'Get-PixelModelOptions', 'Get-PixelModelChoice', 'Get-PixelModelData',
    'Get-PixelModelTitle', 'Get-NextPixelModelChoice', 'Get-PixelUsageRows', 'Get-PixelCodexQuota', 'Get-PixelQuotaPeriod', 'Get-PixelQuotaHit')
foreach ($definition in $ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $modelFunctions
}, $true)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
function New-TestWindow($used) { @{ UsedPercent = $used; ResetTime = '2026-01-01T00:00:00Z' } }
$script:PixelAntigravityOld = $false; $script:PixelClaudeOld = $false
$script:PixelAntigravityUsage = @{ Groups = @(
    @{ Name = 'Gemini Models';         FiveHour = (New-TestWindow 5);   Weekly = (New-TestWindow 34) },
    @{ Name = 'Claude and GPT models'; FiveHour = (New-TestWindow 100); Weekly = (New-TestWindow 71) },
    @{ Name = 'Gemini 4 Argon';        FiveHour = $null;                Weekly = (New-TestWindow 5.4) }
) }
$script:PixelClaudeUsage = @{
    FiveHour = @{ Utilization = 4;  ResetsAt = '2026-01-01T00:00:00Z' }
    SevenDay = @{ Utilization = 32; ResetsAt = '2026-01-01T00:00:00Z' }
    Models   = @( @{ Name = 'Opus'; FiveHour = $null; SevenDay = @{ Utilization = 61; ResetsAt = '2026-01-01T00:00:00Z' } } )
}
$script:PixelCodexUsage = @{
    Windows = @( @{ UsedPercent = 7; WindowSecs = 18000; ResetAt = 1 }, @{ UsedPercent = 9; WindowSecs = 604800; ResetAt = 1 } )
    Extra   = @( @{ Name = 'Code review'; Windows = @( @{ UsedPercent = 44; WindowSecs = 604800; ResetAt = 1 } ) } )
}
$script:ModelChoice = @{}
function Get-Row($provider, $period) { (Get-PixelUsageRows $period) | Where-Object { $_.Provider -eq $provider } }

# 기본값
Assert-Equal 'Gemini Models' (Get-PixelModelChoice 'Antigravity') "Antigravity defaults to the Gemini group"
Assert-Equal 5 (Get-Row 'antigravity' '5H').Used "Default Antigravity row shows Gemini, not the highest group"
Assert-Equal '__auto__' (Get-PixelModelChoice 'Claude') "Claude defaults to the overall quota"
Assert-Equal 4 (Get-Row 'claude' '5H').Used "Default Claude row is the overall 5H quota"
Assert-Equal 7 (Get-Row 'codex' '5H').Used "Default Codex row is the overall 5H quota"

# Antigravity 선택
$script:ModelChoice['Antigravity'] = '__auto__'
Assert-Equal 100 (Get-Row 'antigravity' '5H').Used "Explicit automatic mode follows the highest group"
$script:ModelChoice['Antigravity'] = 'Gemini 4 Argon'
Assert-True ($null -eq (Get-Row 'antigravity' '5H').Used) "A group without a 5H window shows no data instead of another group's value"
Assert-Equal 5.4 (Get-Row 'antigravity' 'WK').Used "Argon weekly quota is readable"
$script:ModelChoice['Antigravity'] = 'Group that no longer exists'
Assert-Equal 'Gemini Models' (Get-PixelModelChoice 'Antigravity') "An unknown saved group falls back to the default"

# Claude / Codex 모델 선택
$script:ModelChoice['Claude'] = 'Opus'
Assert-Equal 61 (Get-Row 'claude' 'WK').Used "Choosing Opus shows the Opus weekly quota"
Assert-True ($null -eq (Get-Row 'claude' '5H').Used) "Opus has no 5H window, so 5H shows no data"
$script:ModelChoice['Codex'] = 'Code review'
Assert-Equal 44 (Get-Row 'codex' 'WK').Used "Choosing a Codex extra limit shows its own window"
$script:ModelChoice = @{}

# 선택지·순환
Assert-Equal '__auto__|Opus' ((Get-PixelModelOptions 'Claude') -join '|') "Claude options: overall + available models"
Assert-Equal '__auto__' ((Get-PixelModelOptions 'Codex')[0]) "Codex options start with the overall quota"
$script:PixelClaudeUsage = @{ FiveHour = @{ Utilization = 4 }; SevenDay = @{ Utilization = 32 }; Models = @() }
Assert-Equal 1 @(Get-PixelModelOptions 'Claude').Count "No per-model data: nothing to switch to"
$seen = @(); $cur = 'Gemini Models'
$options = Get-PixelModelOptions 'Antigravity'
for ($i = 0; $i -lt 4; $i++) { $cur = Get-NextPixelModelChoice -Options $options -Current $cur; $seen += $cur }
Assert-Equal 'Claude and GPT models|Gemini 4 Argon|__auto__|Gemini Models' ($seen -join '|') "Clicking cycles Gemini -> Claude-GPT -> Argon -> highest -> Gemini"

# 표시 이름·히트 영역
Assert-Equal 'Gemini' (Get-AntigravityGroupShortName 'Gemini Models') "Short name drops 'Models'"
Assert-Equal 'Claude-GPT' (Get-AntigravityGroupShortName 'Claude and GPT models') "Short name joins 'and'"
Assert-Equal 'ANTIGRAVITY - GEMINI' (Get-PixelModelTitle 'Antigravity') "Title shows the default Gemini group"
Assert-Equal 'CLAUDE' (Get-PixelModelTitle 'Claude') "Title stays plain when the overall quota is shown"
foreach ($row in 0..2) {
    $hit = Get-PixelQuotaHit 100 (40 + $row * 102 + 10)
    Assert-True ($hit.Title -eq $true -and $hit.Provider -eq @('Claude','Codex','Antigravity')[$row]) "Title row $row is clickable"
}
Assert-True ((Get-PixelQuotaHit 100 (40 + 35)).Title -ne $true) "Quota rows still select the tray source"

# --- Test 17: per-model readings from the Claude and Codex usage responses ---
Write-Host "[17] Claude/Codex model parsing..." -ForegroundColor Yellow
foreach ($definition in $ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('Fetch-ClaudeUsage', 'Fetch-CodexUsage', 'Get-ClaudeConstants', 'Get-JwtClaim')
}, $true)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Write-Log { param($Message, $Level) }
function Invoke-RestMethod { param($Uri, $Method, $Headers, $TimeoutSec, $ErrorAction) return $script:FakeResponse }
$script:AllowClaudeTokenRefresh = $false
$script:FakeResponse = '{"five_hour":{"utilization":4.0,"resets_at":"2026-10-23T11:49:59+00:00"},"seven_day":{"utilization":32.0,"resets_at":"2026-10-25T21:59:59+00:00"},"seven_day_opus":{"utilization":61.5,"resets_at":"2026-10-25T21:59:59+00:00"},"seven_day_sonnet":null}' | ConvertFrom-Json
$c = Fetch-ClaudeUsage -Creds @{ Token = 'x' }
Assert-Equal 1 @($c.Models).Count "Only non-null Claude model limits are listed"
Assert-Equal 'Opus' $c.Models[0].Name "Claude Opus limit is read"
Assert-Equal 61.5 $c.Models[0].SevenDay.Utilization "Claude Opus weekly utilization is read"
$script:FakeResponse = '{"five_hour":{"utilization":4.0,"resets_at":"2026-10-23T11:49:59+00:00"},"seven_day":{"utilization":32.0,"resets_at":"2026-10-25T21:59:59+00:00"},"seven_day_opus":null,"seven_day_sonnet":null}' | ConvertFrom-Json
Assert-Equal 0 @((Fetch-ClaudeUsage -Creds @{ Token = 'x' }).Models).Count "Plans without model limits get an empty list"

$script:FakeResponse = '{"plan_type":"team","rate_limit":{"primary_window":{"used_percent":7,"limit_window_seconds":18000,"reset_at":1},"secondary_window":{"used_percent":9,"limit_window_seconds":604800,"reset_at":2}},"code_review_rate_limit":{"primary_window":{"used_percent":44,"limit_window_seconds":604800,"reset_at":3}},"additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_at":4},"secondary_window":{"used_percent":20,"limit_window_seconds":604800,"reset_at":5}}}]}' | ConvertFrom-Json
$x = Fetch-CodexUsage -Creds @{ Token = 'x' }
Assert-Equal 2 @($x.Windows).Count "Codex overall windows are unchanged"
Assert-Equal 'GPT-5.3-Codex-Spark|Code review' (@($x.Extra | ForEach-Object { $_.Name }) -join '|') "Codex extra limits are read"
Assert-Equal 20 $x.Extra[0].Windows[1].UsedPercent "Codex extra weekly window is read"
$script:FakeResponse = '{"plan_type":"team","rate_limit":{"primary_window":{"used_percent":7,"limit_window_seconds":18000,"reset_at":1}},"code_review_rate_limit":null,"additional_rate_limits":null}' | ConvertFrom-Json
Assert-Equal 0 @((Fetch-CodexUsage -Creds @{ Token = 'x' }).Extra).Count "Codex without extra limits gets an empty list"
Remove-Item -LiteralPath function:Invoke-RestMethod

Write-Host "=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $passed" -ForegroundColor Green
if ($failed -gt 0) {
    Write-Host "  Failed: $failed" -ForegroundColor Red
    exit 1
} else {
    Write-Host "  Failed: 0" -ForegroundColor Green
    Write-Host ""
    Write-Host "All tests passed. AIUsageBar is functional." -ForegroundColor Green
    exit 0
}
