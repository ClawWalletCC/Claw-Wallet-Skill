# claw wallet minimal installer for Windows (PowerShell)
# Served at: https://www.clawwallet.cc/skills/install.ps1
# Usage: first-time install (wallet init) | upgrade (CLAW_WALLET_SKIP_INIT=1, no wallet init)
$ErrorActionPreference = "Stop"
# When upgrade runs the script from a temp file, CLAW_WALLET_INSTALL_DIR is the skill directory
if ($env:CLAW_WALLET_INSTALL_DIR) {
    $ScriptDir = $env:CLAW_WALLET_INSTALL_DIR
} else {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
Set-Location -Path $ScriptDir

$BaseUrl = if ($env:CLAW_WALLET_BASE_URL) { $env:CLAW_WALLET_BASE_URL } else { "https://www.clawwallet.cc" }

function Download-SkillBundle {
    Write-Host "Downloading SKILL.md and wrapper scripts from $BaseUrl ..."
    $skillMd = Join-Path $ScriptDir "SKILL.md"
    Invoke-WebRequest -Uri "$BaseUrl/skills/SKILL.md" -OutFile $skillMd -UseBasicParsing
    $ps1 = Join-Path $ScriptDir "claw-wallet.ps1"
    Invoke-WebRequest -Uri "$BaseUrl/skills/claw-wallet.ps1" -OutFile $ps1 -UseBasicParsing
    $cmdPath = Join-Path $ScriptDir "claw-wallet.cmd"
    try {
        Invoke-WebRequest -Uri "$BaseUrl/skills/claw-wallet.cmd" -OutFile $cmdPath -UseBasicParsing
    } catch {
        Write-Host "Note: claw-wallet.cmd not available from server (optional)."
    }
}

if ($env:CLAW_WALLET_SKIP_SKILL_DOWNLOAD -ne "1") {
    Download-SkillBundle
}

$BinaryUrl = "$BaseUrl/bin/clay-sandbox-windows-amd64.exe"
$BinaryTarget = Join-Path $ScriptDir "clay-sandbox.exe"
$PidPath = Join-Path $ScriptDir "sandbox.pid"
$LogPath = Join-Path $ScriptDir "sandbox.log"
$ErrLogPath = Join-Path $ScriptDir "sandbox_err.log"

function Get-RunningSandboxPid {
    if (-not (Test-Path $PidPath)) { return $null }
    try {
        $raw = (Get-Content -Path $PidPath -TotalCount 1 -ErrorAction SilentlyContinue)
        $pidValue = "$raw".Trim()
        if (-not $pidValue) { return $null }
        $pidInt = [int]$pidValue
        $proc = Get-Process -Id $pidInt -ErrorAction SilentlyContinue
        if ($proc) { return $pidInt }
    } catch {
    }
    try { Remove-Item -Path $PidPath -Force -ErrorAction SilentlyContinue } catch { }
    return $null
}

function Prepare-LogPaths {
    try {
        if (-not (Test-Path $ScriptDir)) { New-Item -ItemType Directory -Path $ScriptDir -Force | Out-Null }
        if (Test-Path $LogPath) { Remove-Item -Path $LogPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path $ErrLogPath) { Remove-Item -Path $ErrLogPath -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType File -Path $LogPath -Force | Out-Null
        New-Item -ItemType File -Path $ErrLogPath -Force | Out-Null
        return
    } catch {
    }
    $baseTemp = $env:TEMP
    if (-not $baseTemp) {
        $baseTemp = Join-Path $env:SystemRoot "Temp"
    }
    $fallbackDir = Join-Path $baseTemp "claw-wallet"
    New-Item -ItemType Directory -Path $fallbackDir -Force | Out-Null
    $script:LogPath = Join-Path $fallbackDir "sandbox.log"
    $script:ErrLogPath = Join-Path $fallbackDir "sandbox_err.log"
    New-Item -ItemType File -Path $LogPath -Force | Out-Null
    New-Item -ItemType File -Path $ErrLogPath -Force | Out-Null
    Write-Host "Warning: could not use logs in $ScriptDir; using fallback logs in $fallbackDir"
}

function Start-Sandbox {
    $runningPid = Get-RunningSandboxPid
    if ($runningPid) {
        Write-Host "claw wallet sandbox is already running."
        Write-Host "PID file: $PidPath"
        Write-Host "Log files: $LogPath , $ErrLogPath"
        return
    }

    Prepare-LogPaths
    $proc = Start-Process -FilePath $BinaryTarget -ArgumentList @("serve") -WorkingDirectory $ScriptDir -RedirectStandardOutput $LogPath -RedirectStandardError $ErrLogPath -WindowStyle Hidden -PassThru
    if ($proc -and $proc.Id) {
        Set-Content -Path $PidPath -Value $proc.Id -Encoding ascii
    }
    Write-Host "claw wallet sandbox launched in the background."
    Write-Host "PID file: $PidPath"
    Write-Host "Log files: $LogPath , $ErrLogPath"
    if (Test-Path (Join-Path $ScriptDir ".env.clay")) {
        Write-Host "API auth: if HTTP returns 401, send header Authorization: Bearer <token> using AGENT_TOKEN from .env.clay . See SKILL.md."
    }
}

function Stop-Sandbox {
    $runningPid = Get-RunningSandboxPid
    if ($runningPid) {
        try { Stop-Process -Id $runningPid -Force -ErrorAction SilentlyContinue } catch { }
    }
    if (Test-Path $BinaryTarget) {
        try { & $BinaryTarget stop *> $null } catch { }
    }
    try { Remove-Item -Path $PidPath -Force -ErrorAction SilentlyContinue } catch { }
}

# --- Common: stop, download, start ---
$SkipStop = $env:CLAW_WALLET_SKIP_STOP -eq "1"
if (-not $SkipStop) {
    Stop-Sandbox
}

Write-Host "Downloading sandbox binary from $BinaryUrl ..."
$TempBinary = "$BinaryTarget.download"
Invoke-WebRequest -Uri $BinaryUrl -OutFile $TempBinary -UseBasicParsing
Move-Item -Path $TempBinary -Destination $BinaryTarget -Force

Start-Sandbox

# --- First-time only: wallet init (skipped when upgrade passes CLAW_WALLET_SKIP_INIT=1) ---
function Do-WalletInit {
    Write-Host "Waiting for sandbox and initializing wallet ..."
    $envClayPath = Join-Path $ScriptDir ".env.clay"
    for ($i = 1; $i -le 90; $i++) {
        $sandboxUrl = $null
        $agentToken = $null
        if (Test-Path $envClayPath) {
            $lines = Get-Content $envClayPath -ErrorAction SilentlyContinue
            foreach ($line in $lines) {
                if ($line -match '^CLAY_SANDBOX_URL=(.+)$') { $sandboxUrl = $matches[1].Trim().Trim('"').Trim("'").TrimEnd() }
                if ($line -match '^(AGENT_TOKEN)=(.+)$') { $agentToken = $matches[2].Trim().Trim('"').Trim("'").TrimEnd() }
            }
        }
        if ($sandboxUrl) {
            try {
                $health = Invoke-RestMethod -Uri "$sandboxUrl/health" -Method Get -ErrorAction Stop
                if ($health.status -eq "ok") {
                    $initParams = @{
                        Uri         = "$sandboxUrl/api/v1/wallet/init"
                        Method      = "Post"
                        Body        = "{}"
                        ErrorAction = "Stop"
                    }
                    if ($agentToken) {
                        $initParams["Headers"] = @{
                            "Authorization" = "Bearer $agentToken"
                            "Content-Type"  = "application/json"
                        }
                    } else {
                        $initParams["Headers"] = @{
                            "Content-Type" = "application/json"
                        }
                    }
                    $initResp = Invoke-RestMethod @initParams
                    if ($initResp) {
                        Write-Host "Wallet initialized."
                    } else {
                        Write-Host "Wallet init request completed."
                    }
                    return
                }
            } catch {
                # Health or init may fail, retry
            }
        }
        Start-Sleep -Seconds 1
    }
    Write-Host "Warning: health not ok or .env.clay not ready after 90s. Check sandbox.log, then run POST {CLAY_SANDBOX_URL}/api/v1/wallet/init manually. If AGENT_TOKEN is empty, local dev mode allows the request without Authorization. See SKILL.md."
}

if ($env:CLAW_WALLET_SKIP_INIT -ne "1") {
    Do-WalletInit
}

# --- Common: final messages ---
Write-Host "Check .env.clay for CLAY_SANDBOX_URL"
Write-Host "If you have set an AGENT_TOKEN, then HTTP clients (curl, agents) must call protected APIs with: Authorization: Bearer <same token>."
Write-Host "Sandbox start success. at: $BinaryTarget"
