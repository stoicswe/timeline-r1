# =============================================================================
# timeline supervisor (Windows) — keeps the r1 timeline endpoint and its public
# tunnel up, and (optionally) republishes the current tunnel URL to the stable
# pointer the creation reads.
#
# Safe to run repeatedly (Scheduled Task every 5 min, and at logon). Idempotent:
#   - starts the endpoint only if it is not already listening
#   - starts a tunnel only if one is not already running
#   - updates the pointer gist only when the URL actually changed
#
# It never reads or writes timeline data itself; it only serves data\timeline.json.
# Configuration comes from server\config.env (written by install.ps1).
# =============================================================================
$ErrorActionPreference = "SilentlyContinue"

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Base = Split-Path -Parent $Here

# --- config.env --------------------------------------------------------------
$cfg = @{}
$cfgPath = Join-Path $Here "config.env"
if (Test-Path $cfgPath) {
  foreach ($line in Get-Content $cfgPath) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
      $cfg[$matches[1]] = $matches[2].Trim()
    }
  }
}

$Port     = if ($env:TIMELINE_PORT) { $env:TIMELINE_PORT } elseif ($cfg.TIMELINE_PORT) { $cfg.TIMELINE_PORT } else { "8791" }
$BindHost = if ($env:TIMELINE_HOST) { $env:TIMELINE_HOST } elseif ($cfg.TIMELINE_HOST) { $cfg.TIMELINE_HOST } else { "127.0.0.1" }
$Cfd      = if ($env:TIMELINE_CFD)  { $env:TIMELINE_CFD }  elseif ($cfg.TIMELINE_CFD)  { $cfg.TIMELINE_CFD }  else { "cloudflared" }
$Token    = if ($env:TIMELINE_TOKEN) { $env:TIMELINE_TOKEN } elseif ($cfg.TIMELINE_TOKEN) { $cfg.TIMELINE_TOKEN } else { "" }
$Gist     = if ($env:POINTER_GIST)  { $env:POINTER_GIST }  elseif ($cfg.POINTER_GIST)  { $cfg.POINTER_GIST }  else { "" }

$State = Join-Path $Here ".state"
$Log   = Join-Path $Here "supervisor.log"
New-Item -ItemType Directory -Force -Path $State | Out-Null

# Resolve a Python interpreter (Windows uses `python`; other hosts may use `python3`).
$PyExe = if ($env:TIMELINE_PYTHON) { $env:TIMELINE_PYTHON }
         elseif (Get-Command python -ErrorAction SilentlyContinue) { "python" }
         elseif (Get-Command python3 -ErrorAction SilentlyContinue) { "python3" }
         else { "python" }

function Log { param($m) Add-Content -Path $Log -Value "$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) $m" }

# Start a background process, hiding its window on Windows (the -WindowStyle
# parameter does not exist on non-Windows PowerShell).
function Start-Hidden {
  param([string]$FilePath, [string[]]$ArgumentList, [string]$OutFile, [string]$ErrFile)
  $p = @{
    FilePath               = $FilePath
    ArgumentList           = $ArgumentList
    PassThru               = $true
    RedirectStandardOutput = $OutFile
    RedirectStandardError  = $ErrFile
  }
  if ($env:OS -eq "Windows_NT") { $p["WindowStyle"] = "Hidden" }
  Start-Process @p | Out-Null
}

# --- endpoint ----------------------------------------------------------------
$healthy = $false
try {
  Invoke-WebRequest -Uri "http://${BindHost}:$Port/health" -UseBasicParsing -TimeoutSec 5 `
    -Headers @{ Authorization = "Bearer $Token" } | Out-Null
  $healthy = $true
} catch { }

if (-not $healthy) {
  Log "endpoint down; starting"
  $env:TIMELINE_PORT = "$Port"
  $env:TIMELINE_HOST = "$BindHost"
  $env:TIMELINE_TOKEN = "$Token"
  $env:TIMELINE_ACCESS_LOG = (Join-Path $State "access.jsonl")
  Start-Hidden -FilePath $PyExe `
    -ArgumentList @(Join-Path $Here "timeline-server.py") `
    -OutFile (Join-Path $Here "endpoint.log") `
    -ErrFile (Join-Path $Here "endpoint.err.log")
  Remove-Item Env:\TIMELINE_PORT, Env:\TIMELINE_HOST, Env:\TIMELINE_TOKEN, Env:\TIMELINE_ACCESS_LOG -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
}

# --- tunnel ------------------------------------------------------------------
$tunnelRunning = $false
$procs = Get-CimInstance Win32_Process -Filter "Name = 'cloudflared.exe'" -ErrorAction SilentlyContinue
foreach ($p in $procs) {
  if ($p.CommandLine -and $p.CommandLine -match "tunnel --url http://${BindHost}:$Port") { $tunnelRunning = $true; break }
}

$tOut = Join-Path $State "tunnel.log"
$tErr = Join-Path $State "tunnel.err.log"
if (-not $tunnelRunning) {
  Log "tunnel down; starting"
  "" | Set-Content $tOut; "" | Set-Content $tErr
  Start-Hidden -FilePath $Cfd `
    -ArgumentList @("tunnel", "--url", "http://${BindHost}:$Port", "--no-autoupdate") `
    -OutFile $tOut -ErrFile $tErr
  for ($i = 0; $i -lt 40; $i++) {
    $m = Select-String -Path $tOut, $tErr -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($m) { break }
    Start-Sleep -Seconds 1
  }
}

$m = Select-String -Path $tOut, $tErr -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' -ErrorAction SilentlyContinue | Select-Object -Last 1
if (-not $m) { Log "no tunnel URL yet; leaving pointer as is"; exit 0 }
$Url = $m.Matches[0].Value
$Url | Set-Content (Join-Path $State "url.current")

# --- pointer -----------------------------------------------------------------
if (-not $Gist) { exit 0 }
$published = ""
$pubPath = Join-Path $State "url.published"
if (Test-Path $pubPath) { $published = (Get-Content $pubPath -Raw).Trim() }
if ($Url -ne $published) {
  $tmp = New-TemporaryFile
  @{ endpoint = $Url; updated = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") } |
    ConvertTo-Json -Compress | Set-Content -Encoding UTF8 $tmp
  & gh gist edit $Gist -f ptr.json $tmp 2>$null
  if ($LASTEXITCODE -eq 0) {
    $Url | Set-Content $pubPath
    Log "pointer updated -> $Url"
  } else {
    Log "pointer update FAILED for $Url"
  }
  Remove-Item $tmp -ErrorAction SilentlyContinue
}

exit 0
