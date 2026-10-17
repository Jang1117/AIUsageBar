# AIUsageBar for Windows - AI Usage Monitor
# System tray application that monitors Claude, Codex, and Antigravity usage
# Zero dependencies: runs on PowerShell 5.1+ with .NET (built into Windows 10/11)
#
# Launch AIUsageBar.exe (built with -noConsole) to avoid allocating a console.
# Running this source in powershell.exe creates a console before it can hide it.

param(
    [switch]$Debug,
    [switch]$Install,
    [switch]$Uninstall,
    # Claude 토큰 갱신을 앱이 직접 하도록 허용한다 (기본: 끔, 읽기 전용).
    # 켜면 ~/.claude/.credentials.json 을 다시 쓰므로 Claude Code 로그인과 충돌할 수 있다. README 참고.
    [switch]$AllowClaudeTokenRefresh,
    [int]$PollIntervalSeconds = 60
)

# --- First-run install prompt ---
$startupDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
$shortcutPath = Join-Path $startupDir "AIUsageBar.lnk"
$configDir = Join-Path $env:USERPROFILE ".aiusagebar"
$installedMarker = Join-Path $configDir ".installed"

# $MyInvocation.MyCommand.Path/$PSCommandPath resolve to a temp extracted .ps1
# (not the real file) once this is compiled with ps2exe — the reliable way to
# find "what is actually running" in both cases is the host process's own exe.
# When run as a plain .ps1, that's powershell.exe itself, so fall back to
# $MyInvocation for the script path in that case.
$hostExePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$script:IsCompiledExe = [System.IO.Path]::GetFileNameWithoutExtension($hostExePath) -notin @('powershell', 'pwsh')
$scriptPath = if ($script:IsCompiledExe) { $hostExePath } else { $MyInvocation.MyCommand.Path }

function New-StartupShortcut {
    param([string]$ShortcutPath, [string]$TargetScriptPath)
    $targetExe = if ($script:IsCompiledExe) { $TargetScriptPath } else {
        # Build.ps1 writes dist\AIUsageBar.exe; a prebuilt exe may sit next to the script
        $candidates = @((Join-Path (Split-Path $TargetScriptPath) "AIUsageBar.exe"),
                        (Join-Path (Join-Path (Split-Path $TargetScriptPath) "dist") "AIUsageBar.exe"))
        $found = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if ($found) { $found } else { $candidates[0] }
    }
    if (-not (Test-Path -LiteralPath $targetExe -PathType Leaf)) {
        throw "Build AIUsageBar.exe first (.\Build.ps1) before enabling startup. See README.md."
    }
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($ShortcutPath)
    $lnk.TargetPath = $targetExe
    $lnk.Arguments = ""
    $lnk.WorkingDirectory = Split-Path $targetExe
    $lnk.Description = "AIUsageBar - AI Usage Monitor"
    $lnk.Save()
}

if ($Uninstall) {
    if (Test-Path $shortcutPath) {
        Remove-Item $shortcutPath -Force
        Write-Host "AIUsageBar removed from startup."
    } else {
        Write-Host "AIUsageBar was not in startup."
    }
    if (Test-Path $installedMarker) { Remove-Item $installedMarker -Force }
    exit 0
}

if ($Install) {
    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
    New-StartupShortcut -ShortcutPath $shortcutPath -TargetScriptPath $scriptPath
    Set-Content -Path $installedMarker -Value (Get-Date -Format o)
    Write-Host "AIUsageBar installed. Will start on login."
    exit 0
}

# Migrate an existing source-based shortcut without changing startup opt-in.
if (Test-Path -LiteralPath $shortcutPath) {
    New-StartupShortcut -ShortcutPath $shortcutPath -TargetScriptPath $scriptPath
}

if (-not (Test-Path $installedMarker)) {
    Add-Type -AssemblyName System.Windows.Forms
    $result = [System.Windows.Forms.MessageBox]::Show(
        "Would you like AIUsageBar to start automatically when you log in?",
        "AIUsageBar Setup",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)

    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }

    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        New-StartupShortcut -ShortcutPath $shortcutPath -TargetScriptPath $scriptPath
    }
    Set-Content -Path $installedMarker -Value (Get-Date -Format o)
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Configuration ---
$script:AppName = "AIUsageBar"
# 기본값은 읽기 전용: 로그인 파일은 읽기만 하고, 만료되면 Claude Code가 갱신하기를 기다린다.
$script:AllowClaudeTokenRefresh = ($AllowClaudeTokenRefresh.IsPresent -or $env:AIUSAGEBAR_CLAUDE_REFRESH -eq '1')
$script:ClaudeLoginExpiredLogged = $false
$script:ConfigDir = Join-Path $env:USERPROFILE ".aiusagebar"
$script:LogFile = Join-Path $script:ConfigDir "aiusagebar.log"
$script:LastClaudeUsage = $null
$script:ClaudeFailCount = 0
$script:ClaudeNextAttempt = [DateTime]::MinValue
$script:LastClaudeAccessToken = $null
# Poll successful readings every minute; retain bounded backoff on failures.
$script:ClaudeMinIntervalSeconds = 50
# Persisted so a restart (an update, a crash, a manual relaunch) doesn't
# reset this to "call it immediately" while Anthropic's side is still
# actively rate-limiting this account's usage endpoint -- restarting used
# to always re-trigger one more 429 on top of whatever caused the limit.
$script:ClaudeBackoffFile = Join-Path $script:ConfigDir "claude_next_attempt.txt"

# Antigravity state
$script:LastAntigravityUsage = $null
$script:AntigravityUsage = $null
$script:AgyFailCount = 0
$script:AgyNextAttempt = [DateTime]::MinValue
$script:AntigravityMinIntervalSeconds = 50
$script:AgyWorker = $null
$script:AgyAsyncResult = $null
$script:AgyTokenCache = $null
$script:AgyRefreshRequested = $false
$script:AgyAuthMissing = $false

if (-not (Test-Path $script:ConfigDir)) {
    New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
}

# Tray color selection includes both provider and quota period. Null selects
# the highest usage across all six quotas. Legacy provider selections use 5H.
$script:SelectionFile = Join-Path $script:ConfigDir "selected_provider.txt"
$script:SelectedProvider = $null
$script:SelectedPeriod = $null
if (Test-Path $script:SelectionFile) {
    try {
        $savedProvider = (Get-Content $script:SelectionFile -Raw -ErrorAction Stop).Trim()
        $savedParts = $savedProvider.Split('|')
        if ($savedParts[0] -in @('Claude','Codex','Antigravity')) {
            $script:SelectedProvider = $savedParts[0]
            $script:SelectedPeriod = if ($savedParts.Count -gt 1 -and $savedParts[1] -in @('5H','WK')) { $savedParts[1] } else { '5H' }
        }
    } catch {}
}

if (Test-Path $script:ClaudeBackoffFile) {
    try {
        $savedAttempt = [DateTime]::Parse((Get-Content $script:ClaudeBackoffFile -Raw -ErrorAction Stop).Trim(), $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        if ($savedAttempt -gt [DateTime]::UtcNow) { $script:ClaudeNextAttempt = $savedAttempt }
    } catch {}
}

# Clean up legacy Antigravity backoff file if present from prior versions
$legacyAgyBackoff = Join-Path $script:ConfigDir "antigravity_next_attempt.txt"
if (Test-Path $legacyAgyBackoff) {
    Remove-Item -Path $legacyAgyBackoff -Force -ErrorAction SilentlyContinue
}

# --- Logging ---
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    if ($Debug) { Write-Host $line }
    Add-Content -Path $script:LogFile -Value $line -ErrorAction SilentlyContinue
}

function Set-ClaudeNextAttempt {
    param([DateTime]$NextAttempt, [switch]$DoNotPersist)
    $script:ClaudeNextAttempt = $NextAttempt
    try {
        if ($DoNotPersist) {
            # Successful polling intervals are process-local throttling, not a
            # failure state that should delay the first fetch after a restart.
            if (Test-Path $script:ClaudeBackoffFile) {
                Remove-Item -Path $script:ClaudeBackoffFile -Force -ErrorAction SilentlyContinue
            }
        } else {
            Set-Content -Path $script:ClaudeBackoffFile -Value $NextAttempt.ToString("o") -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Set-AntigravityNextAttempt {
    param([DateTime]$NextAttempt)
    $script:AgyNextAttempt = $NextAttempt
}

# --- Credential Readers ---
# --- Provider constants -------------------------------------------------------
# 서비스 쪽 사정이 바뀌어 요청이 거부되면 먼저 여기를 확인한다. 모두 비공식(문서화되지 않은) 값이다.
function Get-ClaudeConstants {
    @{
        # Claude Code가 쓰는 공개 OAuth 클라이언트 ID
        OAuthClientId    = '9d1c250a-e61b-44d9-88ed-5944d1962f5e'
        TokenUrl         = 'https://platform.claude.com/v1/oauth/token'
        UsageUrl         = 'https://api.anthropic.com/api/oauth/usage'
        # 토큰 갱신 요청은 Claude Code(Axios)와 같은 식별 문자열이어야 WAF에 막히지 않는다
        RefreshUserAgent = 'axios/1.13.6'
        # 사용량 엔드포인트는 요청 식별 문자열별로 한도를 둔다. 일반 문자열은 곧바로 429가 나므로
        # Claude Code와 같은 형식을 쓴다. 막히면 AIUSAGEBAR_CLAUDE_USER_AGENT 로 바꿀 수 있다.
        UsageUserAgent   = if ($env:AIUSAGEBAR_CLAUDE_USER_AGENT) { $env:AIUSAGEBAR_CLAUDE_USER_AGENT } else { 'claude-code/2.1.0' }
    }
}

function Get-AntigravityConstants {
    # Antigravity CLI가 쓰는 공개 설치형 앱 OAuth 클라이언트. client_secret은 소스에 넣지 않는다:
    # 공개 저장소에 올리면 비밀 검사기(GitHub push protection)가 막는다.
    # 환경 변수 AIUSAGEBAR_AGY_OAUTH_CLIENT_SECRET 또는 ~/.aiusagebar/config.json 의
    # "antigravityOAuthClientSecret" 으로 지정하면 토큰 갱신이 켜지고, 없으면 갱신 없이
    # CLI가 저장한 토큰이 유효한 동안만 조회한다 (만료되면 agy를 한 번 실행하면 된다).
    $secret = $env:AIUSAGEBAR_AGY_OAUTH_CLIENT_SECRET
    if (-not $secret) {
        $cfg = Join-Path (Join-Path $env:USERPROFILE '.aiusagebar') 'config.json'
        if (Test-Path -LiteralPath $cfg) {
            try { $secret = (Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json).antigravityOAuthClientSecret } catch {}
        }
    }
    $userAgent = $env:AIUSAGEBAR_AGY_USER_AGENT
    if (-not $userAgent) { $userAgent = 'antigravity/cli/1.4.0 windows/amd64' }
    @{
        OAuthClientId     = '1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com'
        OAuthClientSecret = $secret
        TokenUrl          = 'https://oauth2.googleapis.com/token'
        QuotaUrl          = 'https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary'
        # 이 API는 CLI 1.4.0 이상으로 보이는 요청에만 Gemini 그룹까지 돌려준다
        UserAgent         = $userAgent
    }
}

# --- Credential Readers ---
function Update-ClaudeCredentialFile {
    # accessToken / refreshToken / expiresAt 세 값만 원문 텍스트에서 바꿔서, Claude Code가 쓴 나머지
    # 필드와 서식은 그대로 두고, 임시 파일을 거쳐 한 번에 교체한다 (쓰는 도중 끊겨도 파일이 깨지지 않음).
    # 파일 구조가 예상과 다르면 아무것도 쓰지 않고 $false를 돌려준다.
    param([string]$CredFile, [string]$AccessToken, [string]$RefreshToken, $ExpiresAtMs)
    $tmp = $CredFile + '.aiusagebar.tmp'
    try {
        $updated = [System.IO.File]::ReadAllText($CredFile)
        $fields = @(
            @{ Name = 'accessToken';  Value = $AccessToken },
            @{ Name = 'refreshToken'; Value = $RefreshToken },
            @{ Name = 'expiresAt';    Value = $ExpiresAtMs }
        )
        foreach ($f in $fields) {
            if ($null -eq $f.Value -or "$($f.Value)" -eq '') { continue }
            $found = [regex]::Matches($updated, '("' + $f.Name + '"\s*:\s*)("[^"\\]*"|-?\d+)')
            if ($found.Count -ne 1) { return $false }
            $m = $found[0]
            if ($f.Name -eq 'expiresAt') {
                # 원래 숫자(밀리초)면 숫자로, 문자열이었으면 ISO 문자열로 같은 형식을 유지한다
                $text = if ($m.Groups[2].Value.StartsWith('"')) {
                    '"' + [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$f.Value).ToString('o') + '"'
                } else { "$([int64]$f.Value)" }
            } else {
                $text = '"' + ($f.Value -replace '\\', '\\' -replace '"', '\"') + '"'
            }
            $updated = $updated.Substring(0, $m.Groups[2].Index) + $text + $updated.Substring($m.Groups[2].Index + $m.Groups[2].Length)
        }
        # 쓰기 전에 결과가 올바른 JSON이고 새 토큰이 들어갔는지 확인
        $check = $updated | ConvertFrom-Json
        if ($AccessToken -and $check.claudeAiOauth.accessToken -ne $AccessToken) { return $false }
        [System.IO.File]::WriteAllText($tmp, $updated, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::Replace($tmp, $CredFile, [NullString]::Value)
        return $true
    } catch {
        Write-Log "Claude: could not update credentials file: $_" "WARN"
        return $false
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Refresh-ClaudeToken {
    param([string]$RefreshToken, [string]$CredFile, [string[]]$Scopes)
    $c = Get-ClaudeConstants
    try {
        # 갱신 토큰은 한 번 쓰면 서버가 새 것으로 바꾼다. 그 사이 Claude Code가 이미 갱신했다면
        # 우리가 가진 토큰은 쓸 수 없으니, 파일의 토큰이 달라졌으면 갱신하지 않고 그 값을 쓰게 한다.
        $current = [System.IO.File]::ReadAllText($CredFile) | ConvertFrom-Json
        if ($current.claudeAiOauth.refreshToken -ne $RefreshToken) {
            Write-Log "Claude: credentials were changed by another process; not refreshing"
            return $null
        }

        $body = @{
            grant_type    = "refresh_token"
            refresh_token = $RefreshToken
            client_id     = $c.OAuthClientId
        }
        if ($Scopes -and $Scopes.Count -gt 0) {
            # OAuth permits a refresh request to repeat (but not expand) the
            # scopes from the original grant. Current Claude Code does this.
            $body.scope = ($Scopes -join " ")
        }

        # Match Claude Code's Axios token request closely. PowerShell's default
        # user agent is treated differently by the WAF in front of this endpoint
        # and can receive persistent 429/403 responses even though opening Claude
        # on the same machine refreshes the very same grant successfully.
        $headers = @{
            "Accept"     = "application/json, text/plain, */*"
            "User-Agent" = $c.RefreshUserAgent
        }
        $response = Invoke-RestMethod -Uri $c.TokenUrl `
            -Method Post -Headers $headers -Body ($body | ConvertTo-Json -Compress) `
            -ContentType "application/json" -TimeoutSec 30 -ErrorAction Stop

        if ($response.access_token) {
            $expiresMs = $null
            if ($response.expires_in) {
                # Claude Code가 쓰는 것과 같은 epoch 밀리초 형식
                $expiresMs = [DateTimeOffset]::UtcNow.AddSeconds($response.expires_in).ToUnixTimeMilliseconds()
            }
            # 쓰기 직전에 한 번 더: 그 사이 다른 프로세스가 파일을 바꿨으면 덮어쓰지 않는다
            $latest = [System.IO.File]::ReadAllText($CredFile) | ConvertFrom-Json
            $saved = $false
            if ($latest.claudeAiOauth.refreshToken -eq $RefreshToken) {
                $saved = Update-ClaudeCredentialFile -CredFile $CredFile -AccessToken $response.access_token `
                    -RefreshToken $response.refresh_token -ExpiresAtMs $expiresMs
            }
            if ($saved) {
                Write-Log "Claude: token refreshed and saved"
            } else {
                Write-Log "Claude: token refreshed but the credentials file was not updated (changed meanwhile or unexpected layout); using it for this poll only" "WARN"
            }
            return $response.access_token
        }
    } catch {
        Write-Log "Claude: token refresh failed: $_" "WARN"
    }
    return $null
}

function Get-ClaudeOAuthToken {
    # Strategy 1: Read from ~/.claude/.credentials.json
    $credFile = Join-Path $env:USERPROFILE ".claude\.credentials.json"
    if (Test-Path $credFile) {
        try {
            $creds = Get-Content $credFile -Raw | ConvertFrom-Json
            if ($creds.claudeAiOauth.accessToken) {
                # Claude Code may refresh the shared credentials file itself. A
                # newly observed token is immediately usable, so do not leave it
                # trapped behind a backoff caused by the previous expired token.
                if ($script:LastClaudeAccessToken -and $script:LastClaudeAccessToken -ne $creds.claudeAiOauth.accessToken) {
                    $script:ClaudeFailCount = 0
                    Set-ClaudeNextAttempt ([DateTime]::MinValue) -DoNotPersist
                    Write-Log "Claude: credentials changed externally; cleared refresh backoff"
                }
                $script:LastClaudeAccessToken = $creds.claudeAiOauth.accessToken

                $expired = $false
                if ($creds.claudeAiOauth.expiresAt) {
                    try {
                        # The `claude` CLI stores this as epoch milliseconds (a number), not an
                        # ISO string — DateTimeOffset::Parse silently fails on that (caught below),
                        # which used to leave $expired permanently false. Handle both forms.
                        $rawExpiresAt = $creds.claudeAiOauth.expiresAt
                        if ($rawExpiresAt -match '^\d+$') {
                            $expiresAt = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$rawExpiresAt).UtcDateTime
                        } else {
                            $expiresAt = [DateTimeOffset]::Parse($rawExpiresAt).UtcDateTime
                        }
                        $expired = $expiresAt -lt [DateTime]::UtcNow
                    } catch {}
                }

                if ($expired -and -not $script:AllowClaudeTokenRefresh) {
                    # 읽기 전용(기본): 로그인 파일은 건드리지 않는다. Claude Code가 토큰을 갱신하면 다음 조회부터
                    # 자동으로 새 값을 읽는다. 앱이 직접 갱신하면 Claude Code의 갱신 토큰과 충돌해 로그아웃될 수 있다.
                    if (-not $script:ClaudeLoginExpiredLogged) {
                        $script:ClaudeLoginExpiredLogged = $true
                        Write-Log "Claude: access token expired; waiting for Claude Code to renew it (token refresh is off, see README)" "WARN"
                    }
                    return @{
                        Token        = $creds.claudeAiOauth.accessToken
                        Source       = "credentials-file-expired-readonly"
                        Expired      = $true
                        LoginExpired = $true
                    }
                }
                $script:ClaudeLoginExpiredLogged = $false

                if ($expired -and $creds.claudeAiOauth.refreshToken) {
                    if ([DateTime]::UtcNow -lt $script:ClaudeNextAttempt) {
                        Write-Log "Claude: skipping token refresh, backing off until $($script:ClaudeNextAttempt.ToString('HH:mm:ss'))Z"
                        return @{
                            Token   = $creds.claudeAiOauth.accessToken
                            Source  = "credentials-file-expired-backoff"
                            Expired = $true
                        }
                    }

                    Write-Log "Claude: token expired, refreshing..."
                    $newToken = Refresh-ClaudeToken -RefreshToken $creds.claudeAiOauth.refreshToken -CredFile $credFile -Scopes $creds.claudeAiOauth.scopes
                    if ($newToken) {
                        return @{ Token = $newToken; Source = "credentials-file-refreshed" }
                    }

                    # Our refresh call can fail even when the token situation is actually fine,
                    # because the `claude` CLI (or another AIUsageBar instance) refreshes the same
                    # OAuth refresh_token independently, and the server rotates/invalidates it after
                    # first use. Whoever loses that race gets a legitimate-looking failure here even
                    # though the credentials file was rewritten with a good token moments before or
                    # after our own read. Re-read the file once more before declaring an outage --
                    # if someone else already fixed it, use that instead of backing off needlessly.
                    try {
                        $recheck = Get-Content $credFile -Raw | ConvertFrom-Json
                        $recheckExpiresAt = $recheck.claudeAiOauth.expiresAt
                        if ($recheck.claudeAiOauth.accessToken -and $recheckExpiresAt) {
                            $recheckExpired = $true
                            if ($recheckExpiresAt -match '^\d+$') {
                                $recheckExpired = ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$recheckExpiresAt).UtcDateTime) -lt [DateTime]::UtcNow
                            } else {
                                $recheckExpired = ([DateTimeOffset]::Parse($recheckExpiresAt).UtcDateTime) -lt [DateTime]::UtcNow
                            }
                            if (-not $recheckExpired) {
                                Write-Log "Claude: refresh failed but credentials file was already updated by another process; using it"
                                $script:ClaudeFailCount = 0
                                return @{ Token = $recheck.claudeAiOauth.accessToken; Source = "credentials-file-recovered-race" }
                            }
                        }
                    } catch {
                        Write-Log "Claude: recheck after failed refresh could not read credentials: $_" "WARN"
                    }

                    # Do not immediately call the usage endpoint with the expired token: that
                    # produces another 401/refresh cycle and can keep extending a rate limit.
                    $script:ClaudeFailCount++
                    $backoffSec = [math]::Min(60 * [math]::Pow(2, $script:ClaudeFailCount), 600)
                    Set-ClaudeNextAttempt ([DateTime]::UtcNow.AddSeconds($backoffSec))
                    Write-Log "Claude: token refresh deferred for ${backoffSec}s" "WARN"
                    return @{
                        Token   = $creds.claudeAiOauth.accessToken
                        Source  = "credentials-file-expired"
                        Expired = $true
                    }
                }

                Write-Log "Claude: loaded token from .credentials.json"
                return @{
                    Token = $creds.claudeAiOauth.accessToken
                    Source = "credentials-file"
                }
            }
        } catch {
            Write-Log "Claude: failed to parse .credentials.json: $_" "WARN"
        }
    }

    # Strategy 2: Environment variable override
    $envToken = $env:AIUSAGEBAR_CLAUDE_OAUTH_TOKEN
    if ($envToken) {
        Write-Log "Claude: using env var AIUSAGEBAR_CLAUDE_OAUTH_TOKEN"
        return @{
            Token = $envToken
            Source = "environment"
        }
    }

    Write-Log "Claude: no credentials found" "WARN"
    return $null
}

function Get-CodexAuthToken {
    $authFile = Join-Path $env:USERPROFILE ".codex\auth.json"
    if (-not (Test-Path $authFile)) {
        Write-Log "Codex: auth.json not found" "WARN"
        return $null
    }

    try {
        $auth = Get-Content $authFile -Raw | ConvertFrom-Json

        # Stock format: { tokens: { access_token, ... } }
        if ($auth.tokens.access_token) {
            Write-Log "Codex: loaded token from auth.json (stock format)"
            return @{
                Token = $auth.tokens.access_token
                Source = "auth-json-stock"
                AccountId = $null
            }
        }

        # Hermes/OpenClaw format: { access_token, ... }
        if ($auth.access_token) {
            Write-Log "Codex: loaded token from auth.json (hermes format)"
            return @{
                Token = $auth.access_token
                Source = "auth-json-hermes"
                AccountId = $null
            }
        }
    } catch {
        Write-Log "Codex: failed to parse auth.json: $_" "WARN"
    }

    return $null
}

function Get-JwtClaim {
    param([string]$Token, [string]$ClaimName)
    try {
        $parts = $Token.Split('.')
        if ($parts.Length -lt 2) { return $null }
        $payload = $parts[1]
        # Fix base64url padding
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

# --- API Fetchers ---
function Fetch-ClaudeUsage {
    param([hashtable]$Creds)
    if (-not $Creds) { return $null }

    $token = $Creds.Token
    $c = Get-ClaudeConstants
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            $headers = @{
                "Authorization"  = "Bearer $token"
                "Accept"         = "application/json"
                "Content-Type"   = "application/json"
                "anthropic-beta" = "oauth-2025-04-20"
                "User-Agent"     = $c.UsageUserAgent
            }

            $response = Invoke-RestMethod -Uri $c.UsageUrl `
                -Method Get -Headers $headers -TimeoutSec 15 -ErrorAction Stop

            $result = @{
                Provider = "Claude"
                FiveHour = @{
                    Utilization = [math]::Round($response.five_hour.utilization, 1)
                    ResetsAt    = $response.five_hour.resets_at
                }
                SevenDay = @{
                    Utilization = [math]::Round($response.seven_day.utilization, 1)
                    ResetsAt    = $response.seven_day.resets_at
                }
            }

            Write-Log "Claude: 5h=$($result.FiveHour.Utilization)% 7d=$($result.SevenDay.Utilization)%"
            return $result
        } catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            if ($statusCode -eq 401 -and -not $script:AllowClaudeTokenRefresh) {
                Write-Log "Claude: 401, token rejected; token refresh is off, run Claude Code to renew the login" "WARN"
            }
            if ($statusCode -eq 401 -and $attempt -eq 0 -and $script:AllowClaudeTokenRefresh) {
                Write-Log "Claude: 401, attempting token refresh..." "WARN"
                $credFile = Join-Path $env:USERPROFILE ".claude\.credentials.json"
                try {
                    if (Test-Path $credFile) {
                        # Another process (the `claude` CLI, or this same tool's own
                        # refresh) can be mid-write to this file at the same instant,
                        # so a read here can race a truncate and return partial/invalid
                        # JSON. That must not escape this handler uncaught -- it's
                        # already inside the outer catch, so a throw here would skip
                        # past our own error handling and crash the whole app.
                        $creds = Get-Content $credFile -Raw | ConvertFrom-Json
                        if ($creds.claudeAiOauth.refreshToken) {
                            $newToken = Refresh-ClaudeToken -RefreshToken $creds.claudeAiOauth.refreshToken -CredFile $credFile -Scopes $creds.claudeAiOauth.scopes
                            if ($newToken) {
                                $token = $newToken
                                continue
                            }
                        }
                    }
                } catch {
                    Write-Log "Claude: failed to read/parse credentials during 401 retry: $_" "WARN"
                }
            }
            Write-Log "Claude: API error: $_" "ERROR"
            return $null
        }
    }
    return $null
}

function Fetch-CodexUsage {
    param([hashtable]$Creds)
    if (-not $Creds) { return $null }

    $accountId = Get-JwtClaim -Token $Creds.Token -ClaimName "https://api.openai.com/auth.chatgpt_account_id"

    try {
        $headers = @{
            "Authorization"      = "Bearer $($Creds.Token)"
            "Accept"             = "application/json"
            "User-Agent"         = "AIUsageBar"
        }
        if ($accountId) {
            $headers["ChatGPT-Account-Id"] = $accountId
        }

        $response = Invoke-RestMethod -Uri "https://chatgpt.com/backend-api/wham/usage" `
            -Method Get -Headers $headers -TimeoutSec 15 -ErrorAction Stop

        $result = @{
            Provider = "Codex"
            PlanType = $response.plan_type
            Windows  = @()
        }

        $rateLimit = $response.rate_limit
        if ($rateLimit.primary_window) {
            $result.Windows += @{
                Name        = "Primary"
                UsedPercent = [math]::Round($rateLimit.primary_window.used_percent, 1)
                ResetAt     = $rateLimit.primary_window.reset_at
                WindowSecs  = $rateLimit.primary_window.limit_window_seconds
            }
        }
        if ($rateLimit.secondary_window) {
            $result.Windows += @{
                Name        = "Weekly"
                UsedPercent = [math]::Round($rateLimit.secondary_window.used_percent, 1)
                ResetAt     = $rateLimit.secondary_window.reset_at
                WindowSecs  = $rateLimit.secondary_window.limit_window_seconds
            }
        }

        $primary = if ($result.Windows.Count -gt 0) { "$($result.Windows[0].UsedPercent)%" } else { "?" }
        Write-Log "Codex: primary=$primary plan=$($result.PlanType)"
        $durations = @($result.Windows | ForEach-Object { "$($_.Name)=$($_.WindowSecs)s" }) -join ', '
        Write-Log "Codex: quota windows: $durations"
        return $result
    } catch {
        Write-Log "Codex: API error: $_" "ERROR"
        return $null
    }
}


function ConvertTo-AntigravityResetString {
    # 리셋 시각을 PowerShell 5.1과 7에서 똑같이 "yyyy-MM-ddTHH:mm:ssZ" 문자열로 맞춘다
    # (7은 JSON의 날짜 문자열을 [DateTime]으로 바꿔서 돌려준다).
    param($Value)
    if ($null -eq $Value) { return $null }
    $format = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime.ToString($format, $invariant) }
    if ($Value -is [DateTime]) {
        $utc = switch ($Value.Kind) {
            'Utc'   { $Value }
            'Local' { $Value.ToUniversalTime() }
            default { [DateTime]::SpecifyKind($Value, 'Utc') }
        }
        return $utc.ToString($format, $invariant)
    }
    return [string]$Value
}

function Parse-AntigravityUsageJson {
    param([string]$JsonText)
    if (-not $JsonText) { return $null }
    try {
        $data = $JsonText | ConvertFrom-Json
        $groups = $data.groups
        if (-not $groups) { $groups = $data.response.groups }
        if (-not $groups) { $groups = $data.summary.groups }
        if (-not $groups) { $groups = $data.command.data.groups }
        if (-not $groups) { return $null }

        $result = @{
            Provider       = "Antigravity"
            Groups         = @()
            MaxUsedPercent = 0.0
        }

        foreach ($g in $groups) {
            $groupObj = @{
                Name        = if ($g.displayName) { $g.displayName } else { $g.name }
                Description = $g.description
                FiveHour    = $null
                Weekly      = $null
            }

            foreach ($b in $g.buckets) {
                if ($b.disabled -eq $true -or $b.disabled -eq 'true') { continue }
                $fraction = $b.remainingFraction
                if ($null -eq $fraction) { $fraction = $b.remaining_fraction }
                if ($null -eq $fraction) { $fraction = $b.remaining.remainingFraction }
                if ($null -eq $fraction) { $fraction = $b.remaining.remaining_fraction }
                if ($null -eq $fraction -and $b.remaining.case -eq 'remainingFraction') { $fraction = $b.remaining.value }
                $remFrac = 0.0
                if ($null -eq $fraction -or $fraction -is [bool] -or -not [double]::TryParse([string]$fraction,
                    [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$remFrac) -or
                    [double]::IsNaN($remFrac) -or [double]::IsInfinity($remFrac)) { continue }
                $remFrac = [math]::Min(1.0, [math]::Max(0.0, $remFrac))
                $remPercent = [math]::Round($remFrac * 100, 1)
                $usedPercent = [math]::Round([math]::Max(0.0, (1.0 - $remFrac) * 100), 1)

                $bucketObj = @{
                    Id                = if ($b.bucketId) { $b.bucketId } else { $b.id }
                    Name              = if ($b.displayName) { $b.displayName } else { $b.name }
                    Window            = $b.window
                    RemainingFraction = $remFrac
                    RemainingPercent  = $remPercent
                    UsedPercent       = $usedPercent
                    ResetTime         = ConvertTo-AntigravityResetString (@($b.resetTime, $b.reset_time, $b.resetAt, $b.reset_at) | Where-Object { $_ } | Select-Object -First 1)
                }

                $label = "$($bucketObj.Id) $($bucketObj.Name) $($b.window)"
                if ($label -match 'week|7d|seven') {
                    $groupObj.Weekly = $bucketObj
                    $result.MaxUsedPercent = [math]::Max($result.MaxUsedPercent, $usedPercent)
                } elseif ($label -match 'session|5h|five|hour') {
                    $groupObj.FiveHour = $bucketObj
                    $result.MaxUsedPercent = [math]::Max($result.MaxUsedPercent, $usedPercent)
                }
            }

            if ($groupObj.FiveHour -or $groupObj.Weekly) { $result.Groups += $groupObj }
        }

        if ($result.Groups.Count -eq 0) { return $null }
        return $result
    } catch {
        return $null
    }
}

# Native Windows credential access and HTTP polling; no subprocesses or CLI fallback.
# API/authentication format verified against the installed CLI and:
# https://github.com/aqua5230/usage/blob/main/loaders/agy_quota_probe.py
# This provider is independently implemented for AIUsageBar.
function Initialize-AntigravityCredentialReader {
    if ('AIUsageBar.NativeCredential' -as [type]) { return }
    # Reflection.Emit avoids Add-Type's external C# compiler at app runtime.
    $name = New-Object System.Reflection.AssemblyName('AIUsageBar.Credentials')
    $assembly = if ($PSVersionTable.PSEdition -eq 'Core') {
        [System.Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly($name, [System.Reflection.Emit.AssemblyBuilderAccess]::Run)
    } else {
        [AppDomain]::CurrentDomain.DefineDynamicAssembly($name, [System.Reflection.Emit.AssemblyBuilderAccess]::Run)
    }
    $module = $assembly.DefineDynamicModule('Credentials')
    $type = $module.DefineType('AIUsageBar.NativeCredential', [System.Reflection.TypeAttributes]'Public, Abstract, Sealed')
    $attributes = [System.Reflection.MethodAttributes]'Public, Static, PinvokeImpl'
    $read = $type.DefinePInvokeMethod('CredReadW', 'advapi32.dll', $attributes,
        [System.Reflection.CallingConventions]::Standard, [bool],
        [type[]]@([string], [uint32], [uint32], [IntPtr].MakeByRefType()),
        [System.Runtime.InteropServices.CallingConvention]::Winapi, [System.Runtime.InteropServices.CharSet]::Unicode)
    $read.SetImplementationFlags([System.Reflection.MethodImplAttributes]::PreserveSig)
    $free = $type.DefinePInvokeMethod('CredFree', 'advapi32.dll', $attributes,
        [System.Reflection.CallingConventions]::Standard, [void], [type[]]@([IntPtr]),
        [System.Runtime.InteropServices.CallingConvention]::Winapi, [System.Runtime.InteropServices.CharSet]::Unicode)
    $free.SetImplementationFlags([System.Reflection.MethodImplAttributes]::PreserveSig)
    [void]$type.CreateType()
}

function ConvertFrom-AntigravityCredentialBlob {
    param([byte[]]$Bytes)
    foreach ($encoding in @([System.Text.Encoding]::Unicode, [System.Text.Encoding]::UTF8)) {
        try {
            $text = $encoding.GetString($Bytes).Trim([char]0, [char]0xFEFF).Trim()
            if ($text.StartsWith('go-keyring-base64:')) {
                $text = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($text.Substring(18)))
            }
            $value = $text | ConvertFrom-Json -ErrorAction Stop
            if ($value.token.access_token -or $value.token.refresh_token) { return $value.token }
        } catch {}
    }
    return $null
}

function Get-AntigravityCredential {
    Initialize-AntigravityCredentialReader
    $pointer = [IntPtr]::Zero
    if ([AIUsageBar.NativeCredential]::CredReadW('gemini:antigravity', 1, 0, [ref]$pointer)) {
        try {
            # CREDENTIALW pointer alignment differs between x86 and x64.
            $sizeOffset = if ([IntPtr]::Size -eq 8) { 32 } else { 24 }
            $blobOffset = if ([IntPtr]::Size -eq 8) { 40 } else { 28 }
            $size = [System.Runtime.InteropServices.Marshal]::ReadInt32($pointer, $sizeOffset)
            if ($size -gt 0 -and $size -le 1048576) {
                $bytes = New-Object byte[] $size
                $blob = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($pointer, $blobOffset)
                [System.Runtime.InteropServices.Marshal]::Copy($blob, $bytes, 0, $size)
                $token = ConvertFrom-AntigravityCredentialBlob -Bytes $bytes
                if ($token) { return $token }
            }
        } finally { [AIUsageBar.NativeCredential]::CredFree($pointer) }
    }
    # Read-only compatibility with older CLI versions.
    $legacyPath = Join-Path $env:USERPROFILE '.gemini/antigravity-cli/antigravity-oauth-token'
    if (Test-Path -LiteralPath $legacyPath) {
        try {
            return ConvertFrom-AntigravityCredentialBlob -Bytes ([System.IO.File]::ReadAllBytes($legacyPath))
        } catch {}
    }
    return $null
}

function Get-AntigravityAccessToken {
    param($CachedToken, [switch]$ForceRefresh)
    $token = $CachedToken
    if ($token -and -not $ForceRefresh) {
        try {
            if ($token.access_token -and [DateTimeOffset]::Parse($token.expiry).UtcDateTime -gt [DateTime]::UtcNow.AddSeconds(60)) {
                return $token
            }
        } catch {}
    }
    $storedToken = Get-AntigravityCredential
    if ($storedToken) { $token = $storedToken }
    if (-not $token) { return $null }
    if (-not $ForceRefresh) {
        try {
            if ($token.access_token -and [DateTimeOffset]::Parse($token.expiry).UtcDateTime -gt [DateTime]::UtcNow.AddSeconds(60)) {
                return $token
            }
        } catch {}
    }
    if (-not $token.refresh_token) {
        if (-not $ForceRefresh -and $token.access_token) { return $token }
        throw 'Antigravity login needs renewal'
    }
    $c = Get-AntigravityConstants
    if (-not $c.OAuthClientSecret) {
        # 갱신용 client_secret이 설정되지 않았다: 갱신 없이 CLI가 저장한 토큰이 유효한 동안만 쓴다
        throw 'Antigravity token expired; start agy once to renew it (automatic renewal needs antigravityOAuthClientSecret, see README)'
    }
    $body = @{
        client_id = $c.OAuthClientId
        client_secret = $c.OAuthClientSecret
        grant_type = 'refresh_token'
        refresh_token = $token.refresh_token
    }
    $response = Invoke-RestMethod -Uri $c.TokenUrl -Method Post `
        -ContentType 'application/x-www-form-urlencoded' -Body $body -TimeoutSec 15 -ErrorAction Stop
    if (-not $response.access_token -or $response.expires_in -le 0) { throw 'Invalid token response' }
    # Keep refreshed credentials only in memory; never modify the CLI's login.
    return [pscustomobject]@{
        access_token = $response.access_token
        refresh_token = $token.refresh_token
        expiry = [DateTime]::UtcNow.AddSeconds([double]$response.expires_in).ToString('o')
    }
}

function Invoke-AntigravityQuotaRequest {
    param([string]$AccessToken)
    # The quota API only returns the Gemini groups (and per-model buckets such as Gemini 4 Argon)
    # to clients identifying as the CLI at 1.4.0 or newer; other user agents get only the Claude/GPT group.
    $c = Get-AntigravityConstants
    $headers = @{ Authorization = "Bearer $AccessToken"; 'User-Agent' = $c.UserAgent }
    return Invoke-RestMethod -Uri $c.QuotaUrl `
        -Method Post -Headers $headers -ContentType 'application/json' -Body '{}' -TimeoutSec 15 -ErrorAction Stop
}

function Invoke-AntigravityDirectPoll {
    param($CachedToken)
    $token = $null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $token = Get-AntigravityAccessToken -CachedToken $CachedToken
        if (-not $token) { return @{ Usage = $null; AuthMissing = $true; Error = 'Login not found'; RetryAfter = 300 } }
        try {
            $response = Invoke-AntigravityQuotaRequest -AccessToken $token.access_token
        } catch {
            $status = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
            if ($status -ne 401) { throw }
            $token = Get-AntigravityAccessToken -CachedToken $token -ForceRefresh
            $response = Invoke-AntigravityQuotaRequest -AccessToken $token.access_token
        }
        $parsed = Parse-AntigravityUsageJson -JsonText ($response | ConvertTo-Json -Depth 30 -Compress)
        if (-not $parsed) { throw 'No supported quota groups' }
        return @{ Usage = $parsed; Token = $token; AuthMissing = $false }
    } catch {
        # Do not log exception bodies or credential-bearing request data.
        $status = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        $retryAfter = 0
        if ($status -eq 429) {
            try { $retryAfter = [int]$_.Exception.Response.Headers['Retry-After'] } catch {}
            $retryAfter = [math]::Min(3600, [math]::Max(60, $retryAfter))
        }
        $errorText = if ($status) { "HTTP $status" }
            elseif ($_.Exception.Message -like 'Antigravity token expired*') { $_.Exception.Message }
            else { 'Credential, network or quota response error' }
        return @{ Usage = $null; Token = $token; AuthMissing = ($status -in @(400, 401)); Error = $errorText; RetryAfter = $retryAfter }
    }
}

function Start-AntigravityPoll {
    if ($script:AgyWorker) { return }
    try {
        Initialize-AntigravityCredentialReader
        $definitions = foreach ($name in @('Get-AntigravityConstants', 'ConvertTo-AntigravityResetString', 'Initialize-AntigravityCredentialReader', 'ConvertFrom-AntigravityCredentialBlob',
            'Get-AntigravityCredential', 'Get-AntigravityAccessToken', 'Invoke-AntigravityQuotaRequest',
            'Parse-AntigravityUsageJson', 'Invoke-AntigravityDirectPoll')) {
            "function $name { $((Get-Item ('function:' + $name)).ScriptBlock.ToString()) }"
        }
        $workerScript = 'param($CachedToken)' + "`n" + ($definitions -join "`n") + "`nInvoke-AntigravityDirectPoll -CachedToken `$CachedToken"
        $script:AgyWorker = [PowerShell]::Create()
        $cachedToken = if ($script:AgyRefreshRequested) { $null } else { $script:AgyTokenCache }
        [void]$script:AgyWorker.AddScript($workerScript).AddArgument($cachedToken)
        $script:AgyAsyncResult = $script:AgyWorker.BeginInvoke()
        $script:AgyRefreshRequested = $false
        if ($script:FastTimer -and -not $script:FastTimer.Enabled) { $script:FastTimer.Start() }
        Write-Log 'Antigravity: direct HTTP poll started (in-process)'
    } catch {
        Stop-AntigravityPoll
        $script:AgyFailCount++
        Set-AntigravityNextAttempt ([DateTime]::UtcNow.AddSeconds(60))
        Write-Log 'Antigravity: could not start in-process poll' 'WARN'
    }
}

function Stop-AntigravityPoll {
    if ($script:AgyWorker) {
        try { $script:AgyWorker.Stop() } catch {}
        $script:AgyWorker.Dispose()
        $script:AgyWorker = $null
    }
    $script:AgyAsyncResult = $null
    if ($script:FastTimer -and $script:FastTimer.Enabled) { $script:FastTimer.Stop() }
}

function Request-AntigravityRefresh {
    # Retain intent while an older worker runs; reread the CLI login next time.
    $script:AgyRefreshRequested = $true
    $script:AgyNextAttempt = [DateTime]::MinValue
}

function Update-AntigravityPoll {
    Check-AntigravityPoll | Out-Null
    if (-not $script:AgyWorker -and ($script:AgyRefreshRequested -or [DateTime]::UtcNow -ge $script:AgyNextAttempt)) {
        Start-AntigravityPoll
    }
}

function Check-AntigravityPoll {
    if (-not $script:AgyWorker -or -not $script:AgyAsyncResult.IsCompleted) { return $false }
    $updated = $false
    try {
        $results = $script:AgyWorker.EndInvoke($script:AgyAsyncResult)
        $result = $results | Select-Object -Last 1
        if ($result.Token) { $script:AgyTokenCache = $result.Token }
        $script:AgyAuthMissing = [bool]$result.AuthMissing
        if ($result.Usage) {
            $script:AntigravityUsage = $result.Usage
            $script:LastAntigravityUsage = $result.Usage
            $script:AgyFailCount = 0
            Set-AntigravityNextAttempt ([DateTime]::UtcNow.AddSeconds($script:AntigravityMinIntervalSeconds))
            Write-Log 'Antigravity: direct HTTP usage updated successfully'
            $summary = @($result.Usage.Groups | ForEach-Object {
                $h5 = if ($_.FiveHour) { "$($_.FiveHour.UsedPercent)%" } else { '--' }
                $wk = if ($_.Weekly) { "$($_.Weekly.UsedPercent)%" } else { '--' }
                "$($_.Name): 5H used=$h5, WK used=$wk"
            }) -join '; '
            Write-Log "Antigravity: $summary"
            $updated = $true
        } else {
            $script:AntigravityUsage = $null
            $script:AgyFailCount++
            $delay = [math]::Max([double]$result.RetryAfter, [math]::Min(60 * [math]::Pow(2, $script:AgyFailCount - 1), 600))
            Set-AntigravityNextAttempt ([DateTime]::UtcNow.AddSeconds($delay))
            Write-Log "Antigravity: direct HTTP poll failed ($($result.Error)); retry in ${delay}s" 'WARN'
        }
    } catch {
        $script:AntigravityUsage = $null
        $script:AgyFailCount++
        Set-AntigravityNextAttempt ([DateTime]::UtcNow.AddSeconds(60))
        Write-Log 'Antigravity: in-process poll failed; keeping cached usage' 'WARN'
    } finally { Stop-AntigravityPoll }
    return $updated
}


# --- UI Helpers ---

function Format-TimeRemaining {
    # $ResetAt: ISO 문자열, epoch 초, [DateTime] 또는 [DateTimeOffset].
    # PowerShell 7은 JSON의 ISO 날짜 문자열을 [DateTime]으로 바꿔 주는데, 이것을 [string]으로 바꾸면
    # 시간대 정보가 사라져("10/18/2026 10:00:00") UTC가 아닌 지역에서 시차만큼 틀어진다. 그래서 형식을 먼저 구분한다.
    param($ResetAt)
    if ($null -eq $ResetAt -or "$ResetAt" -eq '') { return "?" }
    try {
        $resetTime = if ($ResetAt -is [DateTimeOffset]) {
            $ResetAt.UtcDateTime
        } elseif ($ResetAt -is [DateTime]) {
            switch ($ResetAt.Kind) {
                'Utc'   { $ResetAt }
                'Local' { $ResetAt.ToUniversalTime() }
                default { [DateTime]::SpecifyKind($ResetAt, 'Utc') }
            }
        } elseif ("$ResetAt" -match '^\d+$') {
            [DateTimeOffset]::FromUnixTimeSeconds([long]"$ResetAt").UtcDateTime
        } else {
            [DateTimeOffset]::Parse("$ResetAt").UtcDateTime
        }
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

function Get-UsageColor {
    param([double]$Percent)
    if ($Percent -lt 50) { return "Green" }
    if ($Percent -lt 75) { return "Yellow" }
    if ($Percent -lt 90) { return "Orange" }
    return "Red"
}

function Get-PixelUsageColor {
    param([double]$Percent)
    $hex = if ($Percent -lt 50) { '#50d69b' } elseif ($Percent -lt 75) { '#56c7e8' } elseif ($Percent -lt 85) { '#ffd166' } elseif ($Percent -lt 95) { '#ff9850' } else { '#ff5d73' }
    return [System.Drawing.ColorTranslator]::FromHtml($hex)
}

function Format-PixelReset {
    param([string]$ResetAt)
    return (Format-TimeRemaining $ResetAt) -replace '(?<=[dDhH])(?=\d)', ' '
}

function Get-PixelQuotaHit {
    param([int]$X, [int]$Y)
    if ($X -lt 12 -or $X -gt 403 -or $Y -lt 40 -or $Y -ge 346) { return $null }
    $index = [int][math]::Floor(($Y-40)/102)
    $offset = ($Y-40)%102
    $period = if ($offset -ge 30 -and $offset -lt 55) { '5H' } elseif ($offset -ge 59 -and $offset -lt 84) { 'WK' } else { $null }
    if (-not $period) { return $null }
    return @{Provider=@('Claude','Codex','Antigravity')[$index];Period=$period}
}

function Get-PixelTrayReading {
    $rows = @(Get-PixelUsageRows '5H') + @(Get-PixelUsageRows 'WK')
    if ($script:SelectedProvider) {
        return $rows | Where-Object { $_.Provider -eq $script:SelectedProvider -and $_.Period -eq $script:SelectedPeriod } | Select-Object -First 1
    }
    return $rows | Where-Object { $null -ne $_.Used } | Sort-Object { [double]$_.Used } -Descending | Select-Object -First 1
}

function Update-PixelTrayIcon {
    if (-not $script:NotifyIcon) { return }
    $row = Get-PixelTrayReading
    $missing = ($null -eq $row -or $null -eq $row.Used)
    $used = if ($missing) { 0 } else { [double]$row.Used }
    $oldIcon = $script:NotifyIcon.Icon
    $script:NotifyIcon.Icon = Get-TrayIcon -MaxUsage $used -NotConnected $missing
    if ($oldIcon) { $oldIcon.Dispose() }
    $shownPeriod = if ($row.DisplayPeriod) { $row.DisplayPeriod } else { $script:SelectedPeriod }
    $label = if ($script:SelectedProvider) { "$($script:SelectedProvider) $shownPeriod" } else { 'Highest' }
    $value = if ($missing) { 'No data' } else { "$($row.Used)%" }
    $old = if ($row.Old) { ' OLD' } else { '' }
    $tooltip = "AIUsageBar - $label`: $value$old"
    $script:NotifyIcon.Text = $tooltip.Substring(0,[math]::Min(63,$tooltip.Length))
}

function Set-PixelQuotaSelection {
    param([string]$Provider, [string]$Period)
    if ($script:SelectedProvider -eq $Provider -and $script:SelectedPeriod -eq $Period) {
        $script:SelectedProvider = $null
        $script:SelectedPeriod = $null
    } else {
        $script:SelectedProvider = $Provider
        $script:SelectedPeriod = $Period
    }
    try {
        if ($script:SelectedProvider) {
            Set-Content -LiteralPath $script:SelectionFile -Value "$($script:SelectedProvider)|$($script:SelectedPeriod)" -ErrorAction Stop
        } elseif (Test-Path -LiteralPath $script:SelectionFile) {
            Remove-Item -LiteralPath $script:SelectionFile -Force -ErrorAction Stop
        }
    } catch { Write-Log 'Unable to save quota selection' 'WARN' }
    # Changing the tray selection uses cached readings, never an extra API request.
    Update-PixelTrayIcon
    Update-PixelUsageFrame
}

function Get-TrayIcon {
    param([double]$MaxUsage, [bool]$NotConnected = $false)
    $size = 16
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    if ($NotConnected) {
        # Gray circle with a white "!" for unauthenticated state
        $color = [System.Drawing.Color]::FromArgb(120, 120, 120)
        $brush = New-Object System.Drawing.SolidBrush($color)
        $g.FillEllipse($brush, 1, 1, $size - 2, $size - 2)
        $font = New-Object System.Drawing.Font("Arial", 9, [System.Drawing.FontStyle]::Bold)
        $textBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        $g.DrawString("!", $font, $textBrush, 4, 0)
        $font.Dispose()
        $textBrush.Dispose()
        $brush.Dispose()
    } else {
        $color = Get-PixelUsageColor $MaxUsage

        $brush = New-Object System.Drawing.SolidBrush($color)
        $g.FillEllipse($brush, 1, 1, $size - 2, $size - 2)

        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(60, 0, 0, 0), 2)
        $sweepAngle = [math]::Min(360, $MaxUsage * 3.6)
        if ($sweepAngle -gt 0) {
            $g.DrawArc($pen, 2, 2, $size - 4, $size - 4, -90, $sweepAngle)
        }
        $pen.Dispose()
        $brush.Dispose()
    }

    $g.Dispose()
    $hIcon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon)
    return $icon
}

$script:PixelGlyphs = @{
    'A' = '01110/10001/10001/11111/10001/10001/10001'
    'B' = '11110/10001/10001/11110/10001/10001/11110'
    'C' = '01111/10000/10000/10000/10000/10000/01111'
    'D' = '11110/10001/10001/10001/10001/10001/11110'
    'E' = '11111/10000/10000/11110/10000/10000/11111'
    'F' = '11111/10000/10000/11110/10000/10000/10000'
    'G' = '01111/10000/10000/10111/10001/10001/01111'
    'H' = '10001/10001/10001/11111/10001/10001/10001'
    'I' = '11111/00100/00100/00100/00100/00100/11111'
    'J' = '00111/00010/00010/00010/00010/10010/01100'
    'K' = '10001/10010/10100/11000/10100/10010/10001'
    'L' = '10000/10000/10000/10000/10000/10000/11111'
    'M' = '10001/11011/10101/10101/10001/10001/10001'
    'N' = '10001/11001/10101/10011/10001/10001/10001'
    'O' = '01110/10001/10001/10001/10001/10001/01110'
    'P' = '11110/10001/10001/11110/10000/10000/10000'
    'Q' = '01110/10001/10001/10001/10101/10010/01101'
    'R' = '11110/10001/10001/11110/10100/10010/10001'
    'S' = '01111/10000/10000/01110/00001/00001/11110'
    'T' = '11111/00100/00100/00100/00100/00100/00100'
    'U' = '10001/10001/10001/10001/10001/10001/01110'
    'V' = '10001/10001/10001/10001/10001/01010/00100'
    'W' = '10001/10001/10001/10101/10101/10101/01010'
    'X' = '10001/10001/01010/00100/01010/10001/10001'
    'Y' = '10001/10001/01010/00100/00100/00100/00100'
    'Z' = '11111/00001/00010/00100/01000/10000/11111'
    '0' = '01110/10001/10011/10101/11001/10001/01110'
    '1' = '00100/01100/00100/00100/00100/00100/01110'
    '2' = '01110/10001/00001/00010/00100/01000/11111'
    '3' = '11110/00001/00001/01110/00001/00001/11110'
    '4' = '00010/00110/01010/10010/11111/00010/00010'
    '5' = '11111/10000/10000/11110/00001/00001/11110'
    '6' = '01110/10000/10000/11110/10001/10001/01110'
    '7' = '11111/00001/00010/00100/01000/01000/01000'
    '8' = '01110/10001/10001/01110/10001/10001/01110'
    '9' = '01110/10001/10001/01111/00001/00001/01110'
    '%' = '11001/11010/00010/00100/01000/01011/10011'
    '-' = '00000/00000/00000/11111/00000/00000/00000'
    '?' = '01110/10001/00001/00010/00100/00000/00100'
    ' ' = '00000/00000/00000/00000/00000/00000/00000'
}
$script:PixelIconData = @{
    'claude' = 'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAC00lEQVR4nO2WXXITQQyEv9aGq4QQzgNVcBj/XCbAgaACJ+GBVfMgze5iL2XeyZRdtmelUavV0hhe1sv635cuN57P7+fMUAhsY4kJSIM9OyJkbGkSzGVQy1jy+IoIjAEiwGkC3hy+TNt4cQnALkeAmALJpA0yoVDayBI2QrIrDynU4UCgBgFi2EbqKuErAHWAAEOaSRNiTXLEsI3dASQyRzgXoHGMgELJvBPq7monDSHURzmzCyUsEXKdnAWi0DRgoHIViuIx7CpfneCbDChAqmAGHk6f/XD63MFcR6QxOTzAyYAgVbkfDk88HJ5sG41i6B9KYFddV9qXswex/RIo2kobLQKhUSyVfsaD+TYDEdi0k7Ygyldd2FBnHoJqmSsyt/ZeRHmLgXayISLWbQ0MFSg7RHoIz0uw0RuDNTVj2gGg59P75qWZNlJMFc+b7RZjRDDPSbRG5ITu+AJupCApYtJL/cEuLckWIQLf2ZKiaXJxMoxXBCsrmAruimBroxKQooC6BDvI+JOTnhnzsF6GyWjbZBWPF+Rd1CX4WrfRZI0wu+KtI62KGHOp3iSB0mmDsydWS2MQ4M0hUQMHAWnkMfu0AWesLsdgbohZXj5j8bxYz6cPSd8DSOhC3bZRBGkTJbj1KPfzJWUvoGoz/eZ44y7ACX2VtCZR9fWfIIAk+5IaVazMs6bVWi5aC+mrhK9HcWCBLBdjPdmqBIFyUVuVLNrAow6uGTHIVQlTxdztQbS1UACxdjqZVUep2pLE9LStNvSg2yq3wmSstK/C72gA4Hg8xsf48QvE/fFp+np892rS9DNCfn34NO35NHh9P32YJXF/eJokPDT1Ou/vdD7npc/udXw6n111rdTe8piD8b8FXzLSIkSP35Lg27dd3/3/A7C2zPbnHodbm1IDBX0oorrk9Pi467wPwDVC6ybvLQW+7Mk9EDF7a1ff8qbfy3pZ/+/6DbY/zWYRJth0AAAAAElFTkSuQmCC'
    'codex' = 'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAFiklEQVR4nMWXT4heZxXGf8+5d5o0f0UKWhEdKyH4r61CjTZ2BpM2gm5SodiuFATBnYtu3Lh11aXLguBGRFSki4pNbDWISlJNsrDR+gcpVKklnUnGSb7v3vO4eM/9JuhME1vRdzOXO+993+c85znPOR/8n5f+k80Prs5HW0iWbZB86rml7s0A6G914/HV+fjZT0lpEwIsFCI0jD9+tn/DIOJWNh1bmY0njyM7IY0TEGRaJx9KHV+dj28UwE1T8ODqfDx5HGmK0eD6UAIbhgF+cBr/5KdL3bGV+YAQhhA8c5MU7cjAI4+4AwghdUaAMWCEkUymAeg6IBFY6ZSMPFpOy1jgHQPd8R+fPDof50aPfaZFmukWWJrowAmWt44QfP9H8sMnEAISFPC9pxtpp3+2PRM7ilBSAlGRSlIDIcisay2s4jvFyYcsW8gJ6gDz8AkDEp7n6TNL/8b4tgysHp2Pyx8TXSALQubefROwlnfV16bSk2rPqlOttjeNJBTw3aexnVefPbPr4LYAjq0Os3F0t3wEFEhTdBUtAffsMV3nFpSNvXUZNgpIqw4upJWpc2vyeF385az13M8bG4sUrH5iGN99RDgrh04UIlNI08FwfiNIJxFgBx850C5xllbcvoVKjw0W59aagRGyuimqArB6dD4uHwE7NSFWBGkWDKRb/WepK8cG6uya6VClQ01xzS1b1WiLDRtCVo6L+xsAZ2mqGEuDsr2w4Mmvi2EUX/5ai6ZsuPaLlLaYVsu5pzuy3ofY+DvYct8PTy4ArHx8Pi7fTyEGQkTWs6ZDoQ+zvmbv36eW8Imp2mPcFAugEqYrqBBO+OtvTTpfOfOL3V+aAMRCiyVfpxvdFJXA5x9vdH/nG9L1+YiLzibCBQJMfetKR7GSFdBdK/LyfXHHA/fPhwUAu302uZor/yXvBiLgc1/BTvOtJ4Jx1vJkt3Q1wNryZxo4ECERUe8GKy0xoNVV9wAxuyZe/kNgRGY7oCm6faQq+N096voAxDefUDHUctxy5eYFrV81cMVIJgvdLO1OLT8A47XhOkD/y98sdfflPBWlVsPb72pETB0gOtH1co6t4L/w+AjEQjeazG4SZSbRBc4ttVPiLpnpvSvh2Xw+Lozoo/fOxgPLIkJKt0KqvHq4Jj3zVOsFX/yqGQbZAtlE0J7sybmaHhIrWrdYiLWULbVh5oVTuWVEQ0YmDk+XYxzCo3XqqWYqJ07a/W1SGkUd2Ku55jAkXR+TdIgezWbwtvdUu6hMIRhTfuWPja0FgOcv9Esf9uxaby295VCDHAI6MWbHbAbRD2pyE4npQvzw200MUlftupbFpx81f/tzga2KUAk2uvKMaf/d79sc9+3rAUvqvOedRoFybG44+cEkdt9wV0TLf8v5pHq3Mp2MgvKaJnSv/cn86tdL3YIB01JYitbGS24KF0Tg29/RrHwqVavNhlPHozreNLZMk9Nkr9PoIIlXX7TOXfiXZiS7zrGi6a85GM2qN15aaJmCon3vCuxE0QB5bEOIqjRsiIAc5FdfzIZf42vPX9j91sW9N5bJBw//Y7OXdu3d35cfZJnSxFH5g83UNAOabqO5aM1NRX3rC1fX5z7/wu3bTkTbDiT3HN4Y9x68rSi/cR4oAdrI4FD7WyW5uJStVFxZm/vi7/buOJhuO5Sev7S3W7983a+tbVrVeBQt+suXNy1hR4EoP24irDkAiolAitedvF9nJuyQh9aQq9HYQNc7R0tSmzeKR1U8sShGY1PK2nnd9HfBhw5tjFu1Bxd/v6f7wKErgwgdPLBLqaSLqA5Y8ddgsL5+nYuXdqb/lgDstO688+yeO/a//8r+g0ta2OzUGCxvXB3YSXj/FQDTuvvw5mhSVQ/tUHXXLlzatefNnv0/Wf8E9IdMml7gZx8AAAAASUVORK5CYII='
    'antigravity' = 'iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAAA1UlEQVR4nO2Y0RHCIBBElx2rsROtiBJSkXZiO7EBSTC5O1i99xcmc8C+gw+AJEmSZEbqc123vq0oHkW3FrvciumchDi0LrjXKtatRIhDy2K96VpaIMShVaFWqq1bx8oCIQ4j0ve0QIjDqN73skCIw8ibx8MCIQ6j0veyQIjDyPQ9LBDiMDp9awuEOByRvqUFQpzS+2Mrlfv1/CIer8/jPWblDXBE71ueBUKcMjr9s3PJG+As6R89C79roAanf9TCZa+Q17v+NywWoUVvpE4QXJIkyR/wBm+sh6jmFaPPAAAAAElFTkSuQmCC'
}

# Pixel face uses the app's cached readings; animation never polls a provider.
function Get-PixelCodexQuota {
    param([string]$Period)
    $windows = @($script:PixelCodexUsage.Windows | Where-Object { $null -ne $_ })
    $weekly = $windows | Where-Object { $_.WindowSecs -eq 604800 } | Select-Object -First 1
    $primary = $windows | Where-Object { $_.WindowSecs -ne 604800 } | Select-Object -First 1
    if ($Period -eq '5H') { return $primary }
    if ($weekly) { return $weekly }
    # A secondary window can have a different duration; keep its real label.
    return $windows | Where-Object { $_ -ne $primary } | Select-Object -First 1
}

function Get-PixelQuotaPeriod {
    param($Quota, [string]$Fallback)
    if (-not $Quota) { return $Fallback }
    $seconds = [long]$Quota.WindowSecs
    if ($seconds -eq 604800) { return 'WK' }
    if ($seconds -gt 0 -and $seconds % 86400 -eq 0) { return "$($seconds / 86400)D" }
    if ($seconds -gt 0 -and $seconds % 3600 -eq 0) { return "$($seconds / 3600)H" }
    if ($seconds -gt 0 -and $seconds % 60 -eq 0) { return "$($seconds / 60)M" }
    return 'PRI'
}

function Get-PixelUsageRows {
    param([string]$Period)
    $rows = @()
    $claude = $script:PixelClaudeUsage
    $quota = if ($Period -eq '5H') { $claude.FiveHour } else { $claude.SevenDay }
    $rows += @{ Provider = 'claude'; Period = $Period; Label = 'CLAUDE A'; Used = $quota.Utilization; Reset = $quota.ResetsAt; Old = $script:PixelClaudeOld }
    $quota = Get-PixelCodexQuota $Period
    $rows += @{ Provider = 'codex'; Period = $Period; DisplayPeriod = (Get-PixelQuotaPeriod $quota $Period); Label = 'CODEX A'; Used = $quota.UsedPercent; Reset = $quota.ResetAt; Old = $false }
    $windows = @($script:PixelAntigravityUsage.Groups | ForEach-Object {
        if ($Period -eq '5H') { $_.FiveHour } else { $_.Weekly }
    } | Where-Object { $null -ne $_ -and $null -ne $_.UsedPercent } | Sort-Object { [double]$_.UsedPercent } -Descending)
    $quota = $windows | Select-Object -First 1
    $rows += @{ Provider = 'antigravity'; Period = $Period; Label = 'ANTIGRAVITY A'; Used = $quota.UsedPercent; Reset = $quota.ResetTime; Old = $script:PixelAntigravityOld }
    return $rows
}

function Draw-PixelText {
    param($Graphics, [int]$X, [int]$Y, [string]$Text, [int]$Scale = 1, [bool]$Right = $false)
    $Text = $Text.ToUpperInvariant()
    if ($Right) { $X -= [math]::Max(0, $Text.Length * 6 - 1) * $Scale }
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $pattern = $script:PixelGlyphs[[string]$Text[$i]]
        if (-not $pattern) { $pattern = $script:PixelGlyphs['?'] }
        $lines = $pattern.Split('/')
        for ($yy = 0; $yy -lt 7; $yy++) {
            for ($xx = 0; $xx -lt 5; $xx++) {
                if ($lines[$yy][$xx] -eq '1') {
                    $Graphics.FillRectangle($script:PixelTextBrush, ($X + ($i * 6 + $xx) * $Scale), ($Y + $yy * $Scale), $Scale, $Scale)
                }
            }
        }
    }
}

function Draw-PixelTerminalNumber {
    param($Graphics, [int]$X, [int]$Y, [string]$Number)
    $patterns = @{'0'='abcdef'; '1'='bc'; '2'='abdeg'; '3'='abcdg'; '4'='bcfg'; '5'='acdfg'; '6'='acdefg'; '7'='abc'; '8'='abcdefg'; '9'='abcdfg'; '-'='g'}
    $segments = @{
        a=@(2,0,10,2); b=@(12,2,2,9); c=@(12,13,2,9); d=@(2,22,10,2)
        e=@(0,13,2,9); f=@(0,2,2,9); g=@(2,11,10,2)
    }
    foreach ($digit in $Number.ToCharArray()) {
        foreach ($segment in $segments.Keys) {
            $rect = $segments[$segment]
            $brush = if ($patterns[[string]$digit].Contains($segment)) { $script:PixelTextBrush } else { $script:PixelTrackBrush }
            $Graphics.FillRectangle($brush, ($X+$rect[0]), ($Y+$rect[1]), $rect[2], $rect[3])
        }
        $X += 18
    }
    if ($Number -ne '--') { Draw-PixelText $Graphics ($X+1) ($Y+14) '%' }
}

function New-PixelUsageTemplate {
    $bitmap = New-Object System.Drawing.Bitmap(420, 352)
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    $pen = [System.Drawing.Pen]::new([System.Drawing.ColorTranslator]::FromHtml('#22694f'))
    $scanPen = [System.Drawing.Pen]::new([System.Drawing.ColorTranslator]::FromHtml('#04130d'))
    try {
        $g.Clear([System.Drawing.ColorTranslator]::FromHtml('#020906'))
        for ($y=0; $y -lt 352; $y+=3) { $g.DrawLine($scanPen,0,$y,419,$y) }
        $g.FillRectangle($script:PixelBackgroundBrush, 8, 6, 404, 27)
        $g.DrawRectangle($pen,8,6,403,26)
        Draw-PixelText $g 18 13 'AI USAGE DASHBOARD' 2
        Draw-PixelText $g 402 16 'TERMINAL' 1 $true
        $names = @('CLAUDE','CODEX','ANTIGRAVITY')
        for ($i=0; $i -lt 3; $i++) {
            $y = 40+$i*102
            $g.FillRectangle($script:PixelBackgroundBrush,8,$y,404,96)
            $g.DrawRectangle($pen,8,$y,403,95)
            Draw-PixelText $g 18 ($y+8) $names[$i] 2
            $g.DrawLine($pen,18,($y+25),401,($y+25))
            Draw-PixelText $g 18 ($y+39) '5H'
            Draw-PixelText $g 18 ($y+68) 'WK'
        }
    } catch { $bitmap.Dispose(); throw } finally { $scanPen.Dispose(); $pen.Dispose(); $g.Dispose() }
    return $bitmap
}

function Draw-PixelUsageValues {
    param($Graphics, [string]$Period, [bool]$UseCache = $false)
    $g = $Graphics
    foreach ($periodName in @('5H','WK')) {
        $rows = @(Get-PixelUsageRows $periodName)
        $offset = if ($periodName -eq '5H') { 30 } else { 59 }
        for ($i=0; $i -lt 3; $i++) {
            $row = $rows[$i]
            $y = 40+$i*102+$offset
            $reset = if ($null -eq $row.Used) { 'NO DATA' } elseif ($row.Reset) { 'RESET '+(Format-PixelReset $row.Reset) } else { 'RESET --' }
            if ($row.Old) { $reset = 'OLD '+(Format-PixelReset $row.Reset) }
            $selected = ($script:SelectedProvider -eq $row.Provider -and $script:SelectedPeriod -eq $periodName)
            $shownPeriod = if ($row.DisplayPeriod) { $row.DisplayPeriod } else { $periodName }
            $key = "$($row.Used)|$reset|$selected|$shownPeriod"
            $index = "$i-$periodName"
            if ($UseCache -and $script:PixelRowKeys[$index] -eq $key) { continue }
            $g.FillRectangle($script:PixelBackgroundBrush, 12, $y, 392, 25)
            Draw-PixelText $g 18 ($y+9) $shownPeriod
            if ($selected) {
                $pen = [System.Drawing.Pen]::new([System.Drawing.ColorTranslator]::FromHtml('#56c7e8'))
                try { $g.DrawRectangle($pen,12,$y,391,24) } finally { $pen.Dispose() }
            }
            $used = $null
            if ($null -ne $row.Used) { $used = [math]::Max(0,[math]::Min(100,[double]$row.Used)) }
            $number = if ($null -eq $used) { '--' } else { [string][math]::Round($used) }
            Draw-PixelTerminalNumber $g 60 $y $number
            for ($segment=0; $segment -lt 10; $segment++) {
                $x = 140+$segment*15
                $g.FillRectangle($script:PixelTrackBrush,$x,($y+8),12,10)
                $fill = if ($null -eq $used) { 0 } else { [int][math]::Round([math]::Max(0,[math]::Min(1,$used/10-$segment))*12) }
                if ($fill -gt 0) {
                    $brush = [System.Drawing.SolidBrush]::new((Get-PixelUsageColor $used))
                    try { $g.FillRectangle($brush,$x,($y+8),$fill,10) } finally { $brush.Dispose() }
                }
                $g.FillRectangle($script:PixelBackgroundBrush,($x+5),($y+8),2,10)
            }
            $savedBrush = $script:PixelTextBrush
            try {
                $script:PixelTextBrush = $script:PixelAmberBrush
                Draw-PixelText $g 400 ($y+10) $reset 1 $true
            } finally { $script:PixelTextBrush = $savedBrush }
            if ($UseCache) {
                $script:PixelRowKeys[$index] = $key
                $script:PixelPicture.Invalidate([System.Drawing.Rectangle]::new(12,$y,392,25))
            }
        }
    }
}

function New-PixelUsageFrame {
    param([string]$Period)
    $bitmap = New-PixelUsageTemplate
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    try { Draw-PixelUsageValues $g $Period } finally { $g.Dispose() }
    return $bitmap
}

function Update-PixelUsageFrame {
    if (-not $script:PixelPicture) { return }
    if (-not $script:PixelPicture.Image) { $script:PixelPicture.Image = New-PixelUsageTemplate }
    $g = [System.Drawing.Graphics]::FromImage($script:PixelPicture.Image)
    try { Draw-PixelUsageValues $g 'BOTH' $true } finally { $g.Dispose() }
}

function Set-PixelMenuAppearance {
    param($Menu)
    $Menu.ShowImageMargin = $false
    $Menu.ShowCheckMargin = $false
    $Menu.Padding = [System.Windows.Forms.Padding]::new(0)
    $Menu.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#03100b')
    $Menu.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#7dffd0')
    $Menu.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::System
    $Menu.AutoClose = $true
}

function Resize-PixelPopup {
    param($Menu)
    # Disable the menu's automatic arrow-column width: the canvas has no submenu.
    $Menu.SuspendLayout()
    try {
        $Menu.AutoSize = $false
        $Menu.Padding = [System.Windows.Forms.Padding]::new(1)
        $width = $script:PixelPicture.Width
        $height = 2
        foreach ($item in $Menu.Items) {
            $itemHeight = if ($item -is [System.Windows.Forms.ToolStripControlHost]) { $script:PixelPicture.Height } else { $item.GetPreferredSize([System.Drawing.Size]::Empty).Height }
            $item.AutoSize = $false
            $item.Margin = [System.Windows.Forms.Padding]::new(0)
            $item.Size = [System.Drawing.Size]::new($width,$itemHeight)
            $height += $itemHeight
        }
        $Menu.Size = [System.Drawing.Size]::new(($width+2),$height)
    } finally { $Menu.ResumeLayout($true) }
    # WinForms reserves an inset even with image/check columns disabled.
    # Match that actual inset on both sides and retain the last item's height.
    if ($Menu.Items.Count) {
        $left = $Menu.Items[0].Bounds.Left
        $top = $Menu.Items[0].Bounds.Top
        $bottom = $Menu.Items[$Menu.Items.Count-1].Bounds.Bottom
        $Menu.Size = [System.Drawing.Size]::new(($width+2*$left),($bottom+$top))
        $Menu.PerformLayout()
    }
}

function Get-PixelPopupLocation {
    param([System.Drawing.Rectangle]$WorkingArea, [System.Drawing.Size]$PopupSize)
    return [System.Drawing.Point]::new([math]::Max($WorkingArea.Left, $WorkingArea.Right-$PopupSize.Width), [math]::Max($WorkingArea.Top, $WorkingArea.Bottom-$PopupSize.Height))
}

function Initialize-PixelPopupNative {
    if ('AIUsageBar.PopupNative' -as [type]) { return }
    $name = [System.Reflection.AssemblyName]::new('AIUsageBar.Popup')
    $assembly = if ($PSVersionTable.PSEdition -eq 'Core') {
        [System.Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly($name, [System.Reflection.Emit.AssemblyBuilderAccess]::Run)
    } else {
        [AppDomain]::CurrentDomain.DefineDynamicAssembly($name, [System.Reflection.Emit.AssemblyBuilderAccess]::Run)
    }
    $module = $assembly.DefineDynamicModule('Popup')
    $type = $module.DefineType('AIUsageBar.PopupNative', [System.Reflection.TypeAttributes]'Public, Abstract, Sealed')
    $method = $type.DefinePInvokeMethod('SetForegroundWindow', 'user32.dll',
        [System.Reflection.MethodAttributes]'Public, Static, PinvokeImpl',
        [System.Reflection.CallingConventions]::Standard, [bool], [type[]]@([IntPtr]),
        [System.Runtime.InteropServices.CallingConvention]::Winapi,
        [System.Runtime.InteropServices.CharSet]::Auto)
    $method.SetImplementationFlags([System.Reflection.MethodImplAttributes]::PreserveSig)
    $getStyle = $type.DefinePInvokeMethod('GetWindowLongW', 'user32.dll',
        [System.Reflection.MethodAttributes]'Public, Static, PinvokeImpl',
        [System.Reflection.CallingConventions]::Standard, [int], [type[]]@([IntPtr],[int]),
        [System.Runtime.InteropServices.CallingConvention]::Winapi,
        [System.Runtime.InteropServices.CharSet]::Unicode)
    $getStyle.SetImplementationFlags([System.Reflection.MethodImplAttributes]::PreserveSig)
    $setStyle = $type.DefinePInvokeMethod('SetWindowLongW', 'user32.dll',
        [System.Reflection.MethodAttributes]'Public, Static, PinvokeImpl',
        [System.Reflection.CallingConventions]::Standard, [int], [type[]]@([IntPtr],[int],[int]),
        [System.Runtime.InteropServices.CallingConvention]::Winapi,
        [System.Runtime.InteropServices.CharSet]::Unicode)
    $setStyle.SetImplementationFlags([System.Reflection.MethodImplAttributes]::PreserveSig)
    [void]$type.CreateType()
}

function Set-PixelPopupToolWindow {
    param($Menu)
    if ($Menu.Handle -eq [IntPtr]::Zero) { return }
    Initialize-PixelPopupNative
    $style = [AIUsageBar.PopupNative]::GetWindowLongW($Menu.Handle,-20)
    # WS_EX_TOOLWINDOW excludes the popup from taskbar/Alt-Tab; clear APPWINDOW.
    $style = ($style -bor 0x80) -band (-bnot 0x40000)
    [AIUsageBar.PopupNative]::SetWindowLongW($Menu.Handle,-20,$style) | Out-Null
}

function Show-PixelPopup {
    param($Menu, [System.Drawing.Rectangle]$WorkingArea = [System.Drawing.Rectangle]::Empty)
    Update-PixelUsageFrame
    Resize-PixelPopup $Menu
    if ($WorkingArea.IsEmpty) {
        $WorkingArea = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
    }
    $location = Get-PixelPopupLocation $WorkingArea $Menu.Size
    # Supply the final coordinates to Show; never move a visible popup.
    Set-PixelPopupToolWindow $Menu
    $Menu.Show($location)
    if ($Menu.Handle -ne [IntPtr]::Zero) {
        Initialize-PixelPopupNative
        [AIUsageBar.PopupNative]::SetForegroundWindow($Menu.Handle) | Out-Null
    }
    $Menu.Focus() | Out-Null
}

function Initialize-PixelUsageView {
    $script:PixelIcons = @{}
    foreach ($provider in $script:PixelIconData.Keys) {
        $stream = [System.IO.MemoryStream]::new([Convert]::FromBase64String($script:PixelIconData[$provider]))
        $original = [System.Drawing.Bitmap]::FromStream($stream)
        try {
            $left = $original.Width; $top = $original.Height; $right = -1; $bottom = -1
            for ($y = 0; $y -lt $original.Height; $y++) {
                for ($x = 0; $x -lt $original.Width; $x++) {
                    if ($original.GetPixel($x, $y).A -gt 0) {
                        $left = [math]::Min($left, $x); $top = [math]::Min($top, $y)
                        $right = [math]::Max($right, $x); $bottom = [math]::Max($bottom, $y)
                    }
                }
            }
            $rect = [System.Drawing.Rectangle]::new($left, $top, ($right - $left + 1), ($bottom - $top + 1))
            $script:PixelIcons[$provider] = $original.Clone($rect, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        } finally { $original.Dispose(); $stream.Dispose() }
    }
    $script:PixelTextBrush = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml('#7dffd0'))
    $script:PixelRuleBrush = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml('#202730'))
    $script:PixelTrackBrush = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml('#0d3326'))
    $script:PixelBackgroundBrush = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml('#03100b'))
    $script:PixelAmberBrush = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml('#ffcf5a'))
    $script:PixelRowKeys = @{}
    $script:PixelPeriod = '5H'
    $script:PixelPicture = New-Object System.Windows.Forms.PictureBox
    $script:PixelPicture.Size = [System.Drawing.Size]::new(420, 352)
    $script:PixelPicture.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#03100b')
    $script:PixelPicture.Add_MouseClick({
        param($sender, $eventArgs)
        if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $hit = Get-PixelQuotaHit $eventArgs.X $eventArgs.Y
            if ($hit) { Set-PixelQuotaSelection $hit.Provider $hit.Period }
        }
    })
    Update-PixelUsageFrame
    $hostItem = [System.Windows.Forms.ToolStripControlHost]::new($script:PixelPicture)
    $hostItem.AutoSize = $false
    $hostItem.Size = [System.Drawing.Size]::new(420, 352)
    $hostItem.Margin = [System.Windows.Forms.Padding]::new(0)
    $hostItem.Padding = [System.Windows.Forms.Padding]::new(0)
    return $hostItem
}

function Stop-PixelUsageView {
    if ($script:PixelTimer) { $script:PixelTimer.Stop(); $script:PixelTimer.Dispose() }
    if ($script:PixelPicture -and $script:PixelPicture.Image) { $script:PixelPicture.Image.Dispose(); $script:PixelPicture.Image = $null }
    foreach ($icon in $script:PixelIcons.Values) { $icon.Dispose() }
    foreach ($brush in @($script:PixelTextBrush, $script:PixelRuleBrush, $script:PixelTrackBrush, $script:PixelBackgroundBrush, $script:PixelAmberBrush)) { if ($brush) { $brush.Dispose() } }
    $script:PixelIcons = @{}
}


# --- Main Application ---
function Start-AIUsageBarTray {
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:NotifyIcon.Text = "AIUsageBar - Loading..."
    $script:NotifyIcon.Icon = Get-TrayIcon -MaxUsage 0
    $script:NotifyIcon.Visible = $true

    # Context menu
    $contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

    $script:ClaudeMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Claude: Loading...")
    $script:ClaudeDetailItem = New-Object System.Windows.Forms.ToolStripMenuItem("  Checking...")
    $script:CodexMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Codex: Loading...")
    $script:CodexDetailItem = New-Object System.Windows.Forms.ToolStripMenuItem("  Checking...")
    $script:AntigravityMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Antigravity: Loading...")
    $script:AntigravityDetailItem = New-Object System.Windows.Forms.ToolStripMenuItem("  Checking...")
    $script:Antigravity3pDetailItem = New-Object System.Windows.Forms.ToolStripMenuItem("  Claude/GPT: Checking...")

    # Clicking a provider narrows the tray icon color to just that provider;
    # clicking it again (or never picking one) goes back to the combined color.
    $script:ClaudeMenuItem.ToolTipText = "Click to color the tray icon by Claude usage only"
    $script:CodexMenuItem.ToolTipText  = "Click to color the tray icon by Codex usage only"
    $script:AntigravityMenuItem.ToolTipText = "Click to color the tray icon by Antigravity usage only"
    $script:ClaudeMenuItem.Checked = ($script:SelectedProvider -eq "Claude")
    $script:CodexMenuItem.Checked  = ($script:SelectedProvider -eq "Codex")
    $script:AntigravityMenuItem.Checked = ($script:SelectedProvider -eq "Antigravity")

    $separator1 = New-Object System.Windows.Forms.ToolStripSeparator
    $separator2 = New-Object System.Windows.Forms.ToolStripSeparator
    $separator3 = New-Object System.Windows.Forms.ToolStripSeparator

    $refreshItem = New-Object System.Windows.Forms.ToolStripMenuItem("Refresh Now")
    $refreshItem.Add_Click({
        $script:ClaudeNextAttempt = [DateTime]::MinValue
        Request-AntigravityRefresh
        Update-Usage
    })

    $openLogItem = New-Object System.Windows.Forms.ToolStripMenuItem("Open Log")
    $openLogItem.Add_Click({ Start-Process notepad.exe $script:LogFile })

    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem("Exit")
    $exitItem.Add_Click({
        Stop-AntigravityPoll
        $script:NotifyIcon.Visible = $false
        $script:NotifyIcon.Dispose()
        [System.Windows.Forms.Application]::Exit()
    })

    Set-PixelMenuAppearance $contextMenu
    $contextMenu.Items.Add((Initialize-PixelUsageView)) | Out-Null
    $contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    $contextMenu.Items.Add($refreshItem) | Out-Null
    $contextMenu.Items.Add($openLogItem) | Out-Null
    $contextMenu.Items.Add($exitItem) | Out-Null
    Resize-PixelPopup $contextMenu

    $script:PopupMenu = $contextMenu
    # Do not attach the automatic menu: it initially shows beside the cursor.
    $script:NotifyIcon.Add_MouseUp({
        param($sender, $eventArgs)
        if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
            Show-PixelPopup $script:PopupMenu
        }
    })

    # Timer for periodic updates
    $script:Timer = New-Object System.Windows.Forms.Timer
    $script:Timer.Interval = $PollIntervalSeconds * 1000
    $script:Timer.Add_Tick({ Update-Usage })
    $script:Timer.Start()

    # Fast timer for checking the in-process Antigravity HTTP worker
    $script:FastTimer = New-Object System.Windows.Forms.Timer
    $script:FastTimer.Interval = 1000
    $script:FastTimer.Add_Tick({
        $updated = Check-AntigravityPoll
        if ($updated -or ($script:AgyRefreshRequested -and -not $script:AgyWorker)) {
            Update-Usage
        }
    })

    # Initial fetch
    Update-Usage

    Write-Log "AIUsageBar started (poll=${PollIntervalSeconds}s)"

    try {
        [Console]::add_CancelKeyPress({
        param($sender, $e)
        $e.Cancel = $true
        Stop-AntigravityPoll
        $script:NotifyIcon.Visible = $false
        $script:NotifyIcon.Dispose()
        [System.Windows.Forms.Application]::Exit()
    })
    } catch {}

    try {
        [System.Windows.Forms.Application]::Run()
    } finally {
        Stop-PixelUsageView
        Stop-AntigravityPoll
        $script:NotifyIcon.Visible = $false
        $script:NotifyIcon.Dispose()
    }
}

function Update-UsageCore {
    $maxUsage = 0

    # --- Claude ---
    $claudeCreds = Get-ClaudeOAuthToken
    $claudeUsage = $null
    if ($claudeCreds -and -not $claudeCreds.Expired) {
        if ([DateTime]::UtcNow -ge $script:ClaudeNextAttempt) {
            $claudeUsage = Fetch-ClaudeUsage -Creds $claudeCreds
            if ($claudeUsage) {
                $script:ClaudeFailCount = 0
                Set-ClaudeNextAttempt ([DateTime]::UtcNow.AddSeconds($script:ClaudeMinIntervalSeconds)) -DoNotPersist
            } else {
                $script:ClaudeFailCount++
                # Anthropic's usage endpoint enforces a fairly tight rate limit; hammering it
                # every PollIntervalSeconds while it's already limiting us just keeps the window
                # open. Back off exponentially (capped at 10 min) until a request succeeds again.
                $backoffSec = [math]::Min(60 * [math]::Pow(2, $script:ClaudeFailCount), 600)
                Set-ClaudeNextAttempt ([DateTime]::UtcNow.AddSeconds($backoffSec))
                Write-Log "Claude: backing off ${backoffSec}s after $($script:ClaudeFailCount) consecutive failures" "WARN"
            }
        } else {
            Write-Log "Claude: next poll scheduled for $($script:ClaudeNextAttempt.ToString('HH:mm:ss'))Z"
        }
    }

    if ($claudeUsage) {
        $script:LastClaudeUsage = $claudeUsage
        $fiveHr = $claudeUsage.FiveHour.Utilization
        $sevenDay = $claudeUsage.SevenDay.Utilization
        $resetIn = Format-TimeRemaining -ResetAt $claudeUsage.FiveHour.ResetsAt
        $weeklyReset = Format-TimeRemaining -ResetAt $claudeUsage.SevenDay.ResetsAt

        $script:ClaudeMenuItem.Text = "Claude: ${fiveHr}% (resets in $resetIn)"
        $script:ClaudeDetailItem.Text = "  Weekly: ${sevenDay}% (resets in $weeklyReset)"
        $maxUsage = [math]::Max($maxUsage, $fiveHr)
    } elseif (-not $claudeCreds) {
        # No credentials at all — this is a genuine "not authenticated" state.
        $script:ClaudeMenuItem.Text = "Claude: Not connected"
        $script:ClaudeDetailItem.Text = "  Click to authenticate..."
        if (-not $script:ClaudeAuthClickWired) {
            $script:ClaudeAuthClickWired = $true
            $script:ClaudeDetailItem.Add_Click({
                try {
                    $authDir = Join-Path ([System.IO.Path]::GetTempPath()) "aiusagebar-auth"
                    if (Test-Path $authDir) { Remove-Item $authDir -Recurse -Force }
                    [System.IO.Directory]::CreateDirectory($authDir) | Out-Null
                    $batFile = Join-Path $authDir "authenticate.bat"
                    Set-Content -Path $batFile -Value "@echo off`r`ncd /d `"$authDir`"`r`nclaude`r`npause" -Encoding ASCII
                    Start-Process $batFile
                } catch {
                    Write-Log "Claude auth click: failed to launch authenticate.bat: $_" "ERROR"
                }
            })
        }
    } elseif ($script:LastClaudeUsage) {
        # We do have credentials, and a prior poll succeeded — this failure is
        # transient (rate limit, network blip, etc.), not a real disconnect.
        # Keep showing the last known numbers instead of crying "Not connected".
        $fiveHr = $script:LastClaudeUsage.FiveHour.Utilization
        $sevenDay = $script:LastClaudeUsage.SevenDay.Utilization
        $resetIn = Format-TimeRemaining -ResetAt $script:LastClaudeUsage.FiveHour.ResetsAt
        $weeklyReset = Format-TimeRemaining -ResetAt $script:LastClaudeUsage.SevenDay.ResetsAt
        $retryTag = if ($claudeCreds.LoginExpired) { " (cached, login expired)" } elseif ($script:ClaudeFailCount -gt 0 -or $claudeCreds.Expired) { " (cached, retrying)" } else { "" }
        $script:ClaudeMenuItem.Text = "Claude: ${fiveHr}% (resets in $resetIn)$retryTag"
        $script:ClaudeDetailItem.Text = "  Weekly: ${sevenDay}% (resets in $weeklyReset)$retryTag"
        $maxUsage = [math]::Max($maxUsage, $fiveHr)
    } elseif ($claudeCreds.LoginExpired) {
        $script:ClaudeMenuItem.Text = "Claude: Login expired"
        $script:ClaudeDetailItem.Text = "  Open Claude Code to renew it"
    } elseif ($claudeCreds.Expired) {
        $retrySeconds = [math]::Max(0, [math]::Ceiling(($script:ClaudeNextAttempt - [DateTime]::UtcNow).TotalSeconds))
        $retryText = if ($retrySeconds -ge 60) { "$( [math]::Ceiling($retrySeconds / 60) )m" } else { "${retrySeconds}s" }
        $script:ClaudeMenuItem.Text = "Claude: Rate limited (retry in $retryText)"
        $script:ClaudeDetailItem.Text = "  Authentication refresh paused"
    } else {
        # Credentials exist but we've never had a successful fetch yet.
        $script:ClaudeMenuItem.Text = "Claude: Fetch failed, retrying..."
        $script:ClaudeDetailItem.Text = "  Check log for details"
    }

    # --- Codex ---
    $codexCreds = Get-CodexAuthToken
    $codexUsage = Fetch-CodexUsage -Creds $codexCreds

    if ($codexUsage) {
        if ($codexUsage.Windows.Count -gt 0) {
            $primary = $codexUsage.Windows[0]
            $resetIn = ""
            if ($primary.ResetAt) {
                $resetIn = " (resets in $(Format-TimeRemaining -ResetAt $primary.ResetAt))"
            }
            $script:CodexMenuItem.Text = "Codex: $($primary.UsedPercent)%$resetIn"
            $maxUsage = [math]::Max($maxUsage, $primary.UsedPercent)
        }
        if ($codexUsage.Windows.Count -gt 1) {
            $weekly = $codexUsage.Windows[1]
            $weeklyReset = if ($weekly.ResetAt) { " (resets in $(Format-TimeRemaining -ResetAt $weekly.ResetAt))" } else { "" }
            $script:CodexDetailItem.Text = "  Weekly: $($weekly.UsedPercent)%$weeklyReset"
        } else {
            $script:CodexDetailItem.Text = "  Plan: $($codexUsage.PlanType)"
        }
    } else {
        $script:CodexMenuItem.Text = "Codex: Not connected"
        $script:CodexDetailItem.Text = "  Run 'codex login' to authenticate"
    }

    # --- Antigravity ---
    # No external CLI, shell, or compiler is launched, including on failure.
    Update-AntigravityPoll

    $antigravityForDisplay = if ($script:AntigravityUsage) { $script:AntigravityUsage } elseif ($script:LastAntigravityUsage) { $script:LastAntigravityUsage } else { $null }

    if ($script:AgyAuthMissing -and -not $antigravityForDisplay) {
        $script:AntigravityMenuItem.Text = "Antigravity: Not connected"
        $script:AntigravityDetailItem.Text = "  Sign in to Antigravity to enable usage"
        $script:Antigravity3pDetailItem.Visible = $false
    } elseif ($antigravityForDisplay) {
        $geminiGroup = $antigravityForDisplay.Groups | Where-Object { $_.Name -like "*Gemini*" } | Select-Object -First 1
        $otherGroup  = $antigravityForDisplay.Groups | Where-Object { $_.Name -notlike "*Gemini*" } | Select-Object -First 1

        $staleTag = if ($script:AntigravityUsage) { "" } else { " (stale)" }

        if ($geminiGroup -and $geminiGroup.FiveHour) {
            $resetIn = Format-TimeRemaining -ResetAt $geminiGroup.FiveHour.ResetTime
            $script:AntigravityMenuItem.Text = "Antigravity (Gemini): $($geminiGroup.FiveHour.UsedPercent)%$staleTag (resets in $resetIn)"
            $maxUsage = [math]::Max($maxUsage, $geminiGroup.FiveHour.UsedPercent)
        } else {
            $script:AntigravityMenuItem.Text = "Antigravity: Connected$staleTag"
        }

        if ($geminiGroup -and $geminiGroup.Weekly) {
            $weeklyReset = Format-TimeRemaining -ResetAt $geminiGroup.Weekly.ResetTime
            $script:AntigravityDetailItem.Text = "  Weekly: $($geminiGroup.Weekly.UsedPercent)% (resets in $weeklyReset)"
            if ($geminiGroup.Weekly.UsedPercent -ge 90) {
                $maxUsage = [math]::Max($maxUsage, $geminiGroup.Weekly.UsedPercent)
            }
        } else {
            $script:AntigravityDetailItem.Text = "  Weekly: No data"
        }

        if ($otherGroup) {
            $h5 = if ($otherGroup.FiveHour) { "$($otherGroup.FiveHour.UsedPercent)%" } else { "-" }
            $wk = if ($otherGroup.Weekly) { "$($otherGroup.Weekly.UsedPercent)%" } else { "-" }
            $wkReset = if ($otherGroup.Weekly) { Format-TimeRemaining -ResetAt $otherGroup.Weekly.ResetTime } else { "" }
            $resetTag = if ($wkReset) { " (resets in $wkReset)" } else { "" }
            $script:Antigravity3pDetailItem.Text = "  Claude/GPT: $h5 (5h) | $wk (Wk$resetTag)"
            $script:Antigravity3pDetailItem.Visible = $true
            if ($otherGroup.FiveHour) {
                $maxUsage = [math]::Max($maxUsage, $otherGroup.FiveHour.UsedPercent)
            }
            if ($otherGroup.Weekly -and $otherGroup.Weekly.UsedPercent -ge 90) {
                $maxUsage = [math]::Max($maxUsage, $otherGroup.Weekly.UsedPercent)
            }
        } else {
            $script:Antigravity3pDetailItem.Visible = $false
        }
    } elseif ($script:AgyWorker) {
        $script:AntigravityMenuItem.Text = "Antigravity: Checking..."
        $script:AntigravityDetailItem.Text = "  Fetching quota..."
        $script:Antigravity3pDetailItem.Visible = $false
    } elseif ($script:AgyFailCount -gt 0) {
        $retrySec = [math]::Max(0, [math]::Ceiling(($script:AgyNextAttempt - [DateTime]::UtcNow).TotalSeconds))
        $script:AntigravityMenuItem.Text = "Antigravity: Fetch failed (retry in ${retrySec}s)"
        $script:AntigravityDetailItem.Text = "  Check log for details"
        $script:Antigravity3pDetailItem.Visible = $false
    } else {
        $script:AntigravityMenuItem.Text = "Antigravity: Initializing..."
        $script:AntigravityDetailItem.Text = "  Starting poll..."
        $script:Antigravity3pDetailItem.Visible = $false
    }

    # Update tray icon and tooltip
    # Fall back to the last-known-good Claude reading (same as the menu items) so a transient
    # fetch failure or an active backoff window doesn't make Claude vanish from the tray.
    $claudeForDisplay = if ($claudeUsage) { $claudeUsage } elseif ($script:LastClaudeUsage) { $script:LastClaudeUsage } else { $null }
    $anyConnected = ($null -ne $claudeForDisplay) -or ($null -ne $codexUsage) -or ($null -ne $antigravityForDisplay)

    $script:PixelClaudeUsage = $claudeForDisplay
    $script:PixelClaudeOld = ($null -eq $claudeUsage -and $script:ClaudeFailCount -gt 0)
    $script:PixelCodexUsage = $codexUsage
    $script:PixelAntigravityUsage = $antigravityForDisplay
    $script:PixelAntigravityOld = ($null -eq $script:AntigravityUsage -and $null -ne $antigravityForDisplay)
    Update-PixelUsageFrame
    Update-PixelTrayIcon
}

# Every branch above assumes well-formed API responses and a credentials file
# that isn't mid-write by another process (the `claude` CLI or another copy of
# this tool can rewrite it at any moment). A single unexpected shape used to be
# able to throw all the way out of this function -- and since it runs on every
# Timer tick, an uncaught error there escapes the WinForms message loop
# entirely, which is what surfaces as the native "AIUsageBar" crash dialog and
# kills the whole tray icon. Catch anything unexpected here, log it with a full
# stack trace so the next occurrence is a one-line log lookup instead of a
# forensic reconstruction, and just skip this tick -- the next poll retries.
function Update-Usage {
    try {
        Update-UsageCore
    } catch {
        Write-Log "Update-Usage: unhandled error: $($_.Exception.Message)" "ERROR"
        $position = $_.InvocationInfo.PositionMessage -replace '\r?\n', ' '
        Write-Log "Update-Usage: at $position" "ERROR"
    }
}

# --- Entry Point ---
Write-Log "=== AIUsageBar for Windows v1.1.4 ==="
Write-Log "Config dir: $script:ConfigDir"
Write-Log "Poll interval: ${PollIntervalSeconds}s"

Start-AIUsageBarTray
