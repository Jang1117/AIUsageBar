# Hi 핑을 보낼 때 cmd 창이 깜빡이는 문제

- 상태: **가이드 작성 (코드 미적용)**
- 대상: `AIUsageBar.ps1`의 `Start-DailyHi` / `Complete-HiJob` (1775~1830번째 줄)
- 증상: 하루 4번(06:00, 11:05, 16:10, 21:15) 자동 핑이 나갈 때, 또는 "Ping now"를 누를 때 cmd(콘솔) 창이 순식간에 떴다가 사라진다.

## 원인

`Start-DailyHi`는 `claude.exe`, `codex.exe`, `agy.EXE`를 이렇게 실행한다(1791~1792번째 줄).

```powershell
Start-Process -FilePath $exe -ArgumentList $t.Args -WorkingDirectory $env:TEMP -WindowStyle Hidden `
    -RedirectStandardInput $inp -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -ErrorAction Stop
```

- 세 파일은 모두 **콘솔 서브시스템 프로그램**이다(실행 파일 헤더 확인). 그런데 `AIUsageBar.exe`는 콘솔이 없는 창 프로그램(`-noConsole`)이라, 자식을 띄울 때마다 **새 콘솔 창이 만들어진다.**
- `-WindowStyle Hidden`은 "창을 만든 뒤 숨겨 달라"(`SW_HIDE`)는 요청일 뿐이다. 창이 먼저 만들어지므로 한 프레임 보였다 사라질 수 있고, 이 CLI들이 안에서 띄우는 자식 프로세스(쉘, 도구 실행)가 새 콘솔을 만들면 그건 숨김 요청이 닿지 않아 그대로 보인다.
- 1분마다 도는 사용량 조회(`Fetch-*Usage`)는 프로그램 안에서 HTTP만 쓰므로 해당 없다(로그에서 확인). 새 프로세스를 띄우는 곳은 이 핑뿐이다.

## 수정 방향

`Start-Process -WindowStyle Hidden` 대신 `System.Diagnostics.ProcessStartInfo`에 `CreateNoWindow = $true`를 주어 실행한다. 이 옵션은 `CREATE_NO_WINDOW`로 전달돼 **콘솔 창을 아예 만들지 않는다.** 자식이 다시 띄우는 프로세스도 그 창 없는 콘솔을 물려받아 창이 뜨지 않는다(자식이 일부러 새 콘솔을 요구하는 경우만 예외).

표준 입출력은 지금처럼 임시 파일로 돌리는 대신 파이프로 받는다. 파일 리다이렉트는 `Start-Process`에서만 가능하고 `ProcessStartInfo`는 파이프만 지원하기 때문이다. 부수 효과로 임시 파일 3개(`.in`, `.out`, `.err`)를 만들고 지우는 코드가 사라진다.

## 수정 방법

**파일**: `AIUsageBar.ps1`

### 1) `Start-DailyHi` (1775~1803번째 줄)

```powershell
# 수정 전 (1786~1796번째 줄)
        $out = Join-Path $env:TEMP "aiusagebar_hi_$($t.Cli).out"
        $err = Join-Path $env:TEMP "aiusagebar_hi_$($t.Cli).err"
        $inp = Join-Path $env:TEMP "aiusagebar_hi_$($t.Cli).in"   # empty stdin so CLIs never wait for input
        try {
            Set-Content -LiteralPath $inp -Value '' -NoNewline
            $proc = Start-Process -FilePath $exe -ArgumentList $t.Args -WorkingDirectory $env:TEMP -WindowStyle Hidden `
                -RedirectStandardInput $inp -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -ErrorAction Stop
            # Touching Handle keeps the exit code readable after the process exits (PowerShell quirk).
            $null = $proc.Handle
            $started += @{ Provider = $t.Provider; SlotKey = $SlotKey; Process = $proc; Out = $out; Err = $err; Started = [DateTime]::UtcNow }
            Write-Log "Hi: sent to $($t.Provider) via $exe"

# 수정 후
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exe
            $psi.Arguments = $t.Args
            $psi.WorkingDirectory = $env:TEMP
            $psi.UseShellExecute = $false          # CreateNoWindow/리다이렉트는 이 값이 $false일 때만 동작
            $psi.CreateNoWindow = $true            # 콘솔 창을 아예 만들지 않는다 (SW_HIDE처럼 만들었다 숨기는 게 아님)
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
            $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.StandardInput.Close()            # 입력 없음(EOF): CLI가 입력을 기다리며 멈추지 않게 한다 (기존 빈 .in 파일 역할)
            # 출력은 비동기로 계속 읽어야 한다. 안 읽으면 파이프가 가득 찰 때 CLI가 쓰기에서 멈춘다.
            $started += @{ Provider = $t.Provider; SlotKey = $SlotKey; Process = $proc
                           OutTask = $proc.StandardOutput.ReadToEndAsync(); ErrTask = $proc.StandardError.ReadToEndAsync()
                           Started = [DateTime]::UtcNow }
            Write-Log "Hi: sent to $($t.Provider) via $exe"
```

`$null = $proc.Handle`(`Start-Process -PassThru`의 종료 코드 문제를 피하던 코드)은 `Process.Start`로 직접 만든 프로세스에는 필요 없어 지운다.

### 2) `Complete-HiJob` (1805~1830번째 줄)

```powershell
# 수정 전 (1815~1828번째 줄)
    $reply = ''
    try { $reply = (Get-Content -LiteralPath $Job.Out -Raw -ErrorAction Stop).Trim() } catch {}
    ...
        $detail = ''
        try { $detail = (Get-Content -LiteralPath $Job.Err -Raw -ErrorAction Stop).Trim() } catch {}
    ...
    foreach ($f in @($Job.Out, $Job.Err)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    return $true

# 수정 후
    $reply = ''
    # 자식이 파이프를 물고 계속 살아 있으면 읽기가 안 끝난다. 타이머(UI) 스레드가 멈추지 않게 최대 3초만 기다린다.
    if ($Job.OutTask.Wait(3000)) { $reply = $Job.OutTask.Result.Trim() }
    ...
        $detail = ''
        if ($Job.ErrTask.Wait(3000)) { $detail = $Job.ErrTask.Result.Trim() }
    ...
    $Job.Process.Dispose()
    return $true
```

타임아웃 경로(`1809~1813번째 줄`, 180초 뒤 `Kill()`)에도 `try { $Job.Process.Dispose() } catch {}`를 `return $true` 앞에 넣어 파이프 핸들이 새지 않게 한다.

`2378~2379번째 줄`(`-SendHiNow`)의 `$j.Process.WaitForExit(180000)`은 `Process` 객체가 그대로라 바꿀 필요 없다.

## 주의할 점

- **`.Result`를 그냥 부르면 UI가 멈출 수 있다.** 프로세스가 끝났어도 그 자식이 파이프 핸들을 상속해 살아 있으면 `ReadToEndAsync`는 끝나지 않는다. `Complete-HiJob`은 15초 타이머에서 UI 스레드로 도니, 위처럼 `Wait(3000)`으로 상한을 둔다. 못 읽었으면 `reply`만 비는 것이고 성공/실패 판정(종료 코드)에는 영향이 없다.
- **출력 인코딩을 UTF-8로 지정했다.** 지금 로그의 한글 답변(`?�녕?�세??`)이 깨져 있는 건, CLI가 UTF-8로 쓴 파일을 `Get-Content`가 시스템 기본 인코딩(한국어 Windows는 CP949)으로 읽기 때문이다. 파이프로 바꾸면서 `StandardOutputEncoding`을 UTF-8로 지정하면 같이 해결된다. 로그 파일 쓰기(`Write-Log`)의 인코딩은 이번 범위가 아니다.
- **`Kill()`은 메인 프로세스만 죽인다.** 지금도 같은 한계이고 이번 수정으로 달라지지 않는다. 프로세스 트리까지 죽이려면 `taskkill /T`가 필요한데, 그걸 부르는 쪽도 창이 안 뜨게(`CreateNoWindow`) 해야 해서 이번에는 넣지 않았다.
- **사용자가 직접 보는 창은 그대로 둔다.** 로그인 안내용 `.bat`(2213~2214번째 줄)과 `notepad.exe`(2092번째 줄)는 사용자에게 보여 주려고 일부러 띄우는 것이라 이번 수정 대상이 아니다.
- **`.cmd`/`.bat`로 해석되는 CLI도 그대로 동작한다.** 지금 세 CLI는 모두 `.exe`로 해석되지만, 나중에 npm 실행 래퍼(`.cmd`)로 해석돼도 `UseShellExecute = $false`에서 `CreateProcess`가 cmd를 거쳐 실행하며 같은 창 없는 설정이 적용된다.

## 확인 방법

1. **기능 회귀**: 트레이 메뉴에서 "Ping now" 실행 → 로그에 `Hi: Claude OK reply=...`, `Hi: Codex OK ...`, `Hi: Antigravity OK ...` 세 줄이 나오고, **한글 답변이 깨지지 않는지** 확인.
2. **임시 파일 정리**: `%TEMP%`에 `aiusagebar_hi_*`가 더 이상 생기지 않는지 확인.
3. **깜빡임 확인**(핵심): "Ping now"를 누르고 15초 동안 화면을 본다. 수정 전에는 그 동안 콘솔 창이 한두 번 비쳤다면, 수정 후에는 전혀 안 보여야 한다. 눈으로 놓치기 쉬우면 핑을 보내는 동안 PowerShell에서 아래를 돌려 본다. 수정 전에는 `claude`/`codex`/`agy`/`conhost` 중 하나가 창 핸들을 잠깐 가지는 줄이 찍히고, 수정 후에는 안 찍혀야 한다(0.02초 간격이라 확률적 확인임).
   ```powershell
   $end = (Get-Date).AddSeconds(20)
   while ((Get-Date) -lt $end) {
       Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(claude|codex|agy|conhost|cmd)$' -and $_.MainWindowHandle -ne 0 } |
           ForEach-Object { '{0:HH:mm:ss.fff} {1} pid={2}' -f (Get-Date), $_.ProcessName, $_.Id }
       Start-Sleep -Milliseconds 20
   }
   ```
4. **타임아웃 경로**: `Complete-HiJob`의 180초를 임시로 5초 정도로 줄이고 오래 걸리는 CLI로 한 번 돌려 `timed out` 로그가 남는지, 이후에도 트레이 앱이 멈추지 않고 계속 갱신되는지 확인(확인 후 원래 값으로 되돌릴 것).
5. **`-SendHiNow` 경로**(2376~2381번째 줄): `AIUsageBar.exe -SendHiNow`를 실행해 종료 코드 0으로 끝나고 로그가 같은 형식으로 남는지 확인.
