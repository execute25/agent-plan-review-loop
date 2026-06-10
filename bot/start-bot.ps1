# plan-bot launcher.
#   start-bot.ps1         -> start the bot if not already running (manual; IGNORES AUTOSTART)
#   start-bot.ps1 -Auto   -> same, but FIRST obey AUTOSTART in bot\.env (0/false/no/off => do nothing)
# Triggered at Windows login by plan-bot.vbs (which passes -Auto). Idempotent: never starts a 2nd poller.
param([switch]$Auto)
$ErrorActionPreference = 'SilentlyContinue'

# Resolve the bot dir from the script's own location, then find python.
# Resolution order: PLAN_PYTHON env var -> PLAN_PYTHON in bot/.env -> PATH (skipping the
# Windows "App execution alias" Store stub, which prints a message and is not a real interpreter).
# No hard-coded machine paths — set PLAN_PYTHON in .env if python isn't a real entry on PATH.
$dir     = $PSScriptRoot
$err     = Join-Path $dir 'bot.err.log'
$out     = Join-Path $dir 'bot.out.log'
$envFile = Join-Path $dir '.env'

$py = $env:PLAN_PYTHON
if (-not $py -and (Test-Path $envFile)) {
    $m = Select-String -Path $envFile -Pattern '^[ \t]*PLAN_PYTHON[ \t]*=' | Select-Object -First 1
    if ($m) { $py = ((($m.Line -split '=', 2)[1]) -split '#', 2)[0].Trim().Trim('"').Trim("'") }
}
if (-not $py) {
    foreach ($c in 'py', 'python', 'python3') {
        $src = (Get-Command $c -ErrorAction SilentlyContinue).Source
        if ($src -and $src -notmatch 'WindowsApps') {
            $probe = & $src -c "print('PYOK')" 2>$null   # a real python prints PYOK; the Store stub does not
            if ($LASTEXITCODE -eq 0 -and $probe -eq 'PYOK') { $py = $src; break }
        }
    }
}

# login path: honour the on/off switch in .env (missing key => default ON)
if ($Auto -and (Test-Path $envFile)) {
    $m = Select-String -Path $envFile -Pattern '^[ \t]*AUTOSTART[ \t]*=' | Select-Object -First 1
    if ($m) {
        $val = ((($m.Line -split '=', 2)[1]) -split '#', 2)[0].Trim().Trim('"').Trim("'").ToLower()
        if ($val -in @('0', 'false', 'no', 'off', '')) { return }   # disabled from config -> don't start
    }
}

# already running? leave it (Telegram allows ONE getUpdates poller per token).
if (@(Get-CimInstance Win32_Process -Filter "name like '%python%'" | Where-Object { $_.CommandLine -like '*plan_bot.py*' }).Count -gt 0) { return }

if (-not $py -or -not (Test-Path $py)) { return }
if (-not (Test-Path (Join-Path $dir 'plan_bot.py'))) { return }

Start-Process -FilePath $py -ArgumentList 'plan_bot.py' -WorkingDirectory $dir `
    -RedirectStandardError $err -RedirectStandardOutput $out
