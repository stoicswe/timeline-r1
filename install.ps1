# =============================================================================
# timeline-r1 — one-command installer for the OS3-side setup (Windows)
#
# Mirrors install.sh. What it does, in order:
#   1. checks prerequisites (Python 3, cloudflared) and offers to fetch
#      cloudflared into a private folder — no admin needed;
#   2. copies the endpoint, supervisor and generator spec into an install dir;
#   3. starts the read-only timeline endpoint with a fresh pairing token;
#   4. starts a Cloudflare quick tunnel to it;
#   5. waits out the tunnel-routability delay the pilot found (~60 s) and
#      verifies the endpoint is actually reachable through the tunnel;
#   6. registers the supervisor as a per-user Scheduled Task (every 5 min +
#      at logon) — no admin needed;
#   7. prints the endpoint URL and token to paste into the r1 creation, and the
#      one thing only you can do on the OS3 side (create the daily generator).
#
# Reviewable and non-destructive: it prints its plan and asks before changing
# anything, and it will not touch an existing install without -Force.
#
# Usage:  powershell -ExecutionPolicy Bypass -File .\install.ps1 [options]
# =============================================================================
[CmdletBinding()]
param(
  [string]$Dir    = (Join-Path $HOME ".timeline-r1"),
  [int]   $Port   = 8791,
  [string]$BindHost = "127.0.0.1",
  [string]$Token  = "",
  [switch]$Pointer,
  [switch]$NoSupervisor,
  [switch]$NoTunnel,
  [switch]$Force,
  [switch]$Yes,
  [switch]$DryRun,
  [switch]$Help
)

$ErrorActionPreference = "Stop"

function Say  { param($m) Write-Host $m }
function Step { param($m) Write-Host ""; Write-Host "==> $m" }
function Warn { param($m) Write-Warning $m }
function Die  { param($m) Write-Error $m; exit 1 }

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
  return Start-Process @p
}

if ($Help) {
  @"
timeline-r1 installer (Windows)

Usage: powershell -ExecutionPolicy Bypass -File .\install.ps1 [options]

Options:
  -Dir DIR        install directory            (default: ~\.timeline-r1)
  -Port N         endpoint port                (default: 8791)
  -BindHost IP    endpoint bind address        (default: 127.0.0.1)
  -Token TOKEN    use this pairing token       (default: generated)
  -Pointer        also publish a pointer gist  (needs gh; default: off)
  -NoSupervisor   do not register the Scheduled Task supervisor
  -NoTunnel       do not start a tunnel (endpoint only; not reachable from r1)
  -Force          overwrite an existing install
  -Yes            do not ask for confirmation
  -DryRun         print the plan and exit without changing anything
  -Help           show this help
"@
  exit 0
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SrcServer = Join-Path $ScriptDir "server"
if (-not (Test-Path (Join-Path $SrcServer "timeline-server.py"))) {
  Die "server\ not found next to this script - run it from a clone of the repo"
}

# --- prerequisites -----------------------------------------------------------
$Python = $null
foreach ($c in @("python", "python3", "py")) {
  $cmd = Get-Command $c -ErrorAction SilentlyContinue
  if ($cmd) {
    try {
      $ok = & $cmd.Source -c "import sys; sys.exit(0 if sys.version_info >= (3,8) else 1)" 2>$null
      if ($LASTEXITCODE -eq 0) { $Python = $cmd.Source; break }
    } catch { }
  }
}

$CfdBin = $null
$cfdCmd = Get-Command cloudflared -ErrorAction SilentlyContinue
if ($cfdCmd) { $CfdBin = $cfdCmd.Source }
elseif (Test-Path (Join-Path $Dir "bin\cloudflared.exe")) { $CfdBin = Join-Path $Dir "bin\cloudflared.exe" }
$NeedCfd = -not $CfdBin

$Existing = Test-Path (Join-Path $Dir "server\config.env")

# --- plan --------------------------------------------------------------------
Step "Plan"
Say "  platform        : windows / $env:PROCESSOR_ARCHITECTURE"
Say "  install dir     : $Dir"
Say "  endpoint        : http://${BindHost}:$Port  (loopback; not directly reachable from the r1)"
Say "  tunnel          : $(if ($NoTunnel) { 'skipped (-NoTunnel)' } else { 'Cloudflare quick tunnel (no account needed)' })"
Say "  pairing token   : $(if ($Token) { 'provided' } else { 'will be generated (32 random bytes)' })"
Say "  supervisor      : $(if ($NoSupervisor) { 'skipped (-NoSupervisor)' } else { 'Scheduled Task: every 5 min + at logon (no admin)' })"
Say "  pointer gist    : $(if ($Pointer) { 'will be published (needs gh)' } else { 'not published (pairing UI does not need one)' })"
Say "  python          : $(if ($Python) { $Python } else { 'NOT FOUND - install Python 3.8+ first (below)' })"
Say "  cloudflared     : $(if ($NeedCfd) { "not found - will download to $Dir\bin\cloudflared.exe" } else { $CfdBin })"
if ($Existing -and -not $Force) {
  Warn "an install already exists at $Dir (config.env present)."
  Warn "re-run with -Force to overwrite it, or -Dir to install elsewhere."
}

if ($DryRun) { Step "Dry run - nothing was changed."; exit 0 }

if (-not $Python) {
  Step "Python is required"
  Say "  Install Python 3.8 or newer, then re-run this installer:"
  Say "    winget install Python.Python.3.12"
  Say "    (or https://www.python.org/downloads/ - tick 'Add python.exe to PATH')"
  exit 1
}

if ($Existing -and -not $Force) {
  Die "refusing to overwrite the existing install at $Dir (use -Force)"
}

if (-not $Yes) {
  $ans = Read-Host "`nProceed with the setup above? [y/N]"
  if ($ans -notmatch '^(y|yes)$') { Say "aborted - nothing was changed."; exit 0 }
}


# --- install files -----------------------------------------------------------
Step "Installing files into $Dir"
foreach ($sub in @("server", "server\.state", "data", "bin")) {
  New-Item -ItemType Directory -Force -Path (Join-Path $Dir $sub) | Out-Null
}
Copy-Item (Join-Path $SrcServer "timeline-server.py")   (Join-Path $Dir "server\timeline-server.py") -Force
Copy-Item (Join-Path $SrcServer "supervise.ps1")        (Join-Path $Dir "server\supervise.ps1") -Force
Copy-Item (Join-Path $SrcServer "generate-timeline.md") (Join-Path $Dir "server\generate-timeline.md") -Force

# --- token -------------------------------------------------------------------
if (-not $Token) {
  $bytes = New-Object 'System.Byte[]' 32
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $Token = -join ($bytes | ForEach-Object { '{0:x2}' -f $_ })
}

# --- empty feed (so the endpoint answers instead of 503 until the generator runs)
$FeedPath = Join-Path $Dir "data\timeline.json"
if (-not (Test-Path $FeedPath)) {
  $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  @{ version = 1; timezone = "UTC"; generatedAt = $now; cards = @() } |
    ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 $FeedPath
}

# --- cloudflared -------------------------------------------------------------
if ($NeedCfd) {
  Step "Downloading cloudflared (no admin; into $Dir\bin)"
  $url = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
  $dest = Join-Path $Dir "bin\cloudflared.exe"
  Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
  $CfdBin = $dest
  & $CfdBin --version | Out-Null
  if ($LASTEXITCODE -ne 0) { Die "cloudflared did not run after download" }
}

# --- start endpoint ----------------------------------------------------------
Step "Starting the endpoint on http://${BindHost}:$Port"
$env:TIMELINE_PORT = "$Port"
$env:TIMELINE_HOST = "$BindHost"
$env:TIMELINE_TOKEN = "$Token"
$env:TIMELINE_ACCESS_LOG = (Join-Path $Dir "server\.state\access.jsonl")
$epOut = Join-Path $Dir "server\endpoint.log"
$epErr = Join-Path $Dir "server\endpoint.err.log"
$ep = Start-Hidden -FilePath $Python -ArgumentList @(Join-Path $Dir "server\timeline-server.py") `
  -OutFile $epOut -ErrFile $epErr
$ep.Id | Set-Content (Join-Path $Dir "server\.state\endpoint.pid")
Remove-Item Env:\TIMELINE_PORT, Env:\TIMELINE_HOST, Env:\TIMELINE_TOKEN, Env:\TIMELINE_ACCESS_LOG -ErrorAction SilentlyContinue

$up = $false
for ($i = 0; $i -lt 15; $i++) {
  try {
    Invoke-WebRequest -Uri "http://${BindHost}:$Port/health" -UseBasicParsing -TimeoutSec 3 `
      -Headers @{ Authorization = "Bearer $Token" } | Out-Null
    $up = $true; break
  } catch { Start-Sleep -Seconds 1 }
}
if (-not $up) { Die "endpoint did not come up - see $epErr" }
Say "  endpoint is up locally."

# --- start tunnel + verify ---------------------------------------------------
$Url = ""
if (-not $NoTunnel) {
  Step "Starting the Cloudflare quick tunnel"
  $tOut = Join-Path $Dir "server\.state\tunnel.log"
  $tErr = Join-Path $Dir "server\.state\tunnel.err.log"
  "" | Set-Content $tOut; "" | Set-Content $tErr
  $cf = Start-Hidden -FilePath $CfdBin `
    -ArgumentList @("tunnel", "--url", "http://${BindHost}:$Port", "--no-autoupdate") `
    -OutFile $tOut -ErrFile $tErr
  $cf.Id | Set-Content (Join-Path $Dir "server\.state\tunnel.pid")

  for ($i = 0; $i -lt 60; $i++) {
    $m = Select-String -Path $tOut, $tErr -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' -ErrorAction SilentlyContinue |
      Select-Object -Last 1
    if ($m) { $Url = $m.Matches[0].Value; break }
    Start-Sleep -Seconds 1
  }
  if (-not $Url) { Die "no tunnel hostname appeared - see $tErr" }
  Say "  tunnel hostname: $Url"
  Say "  waiting for it to become routable (the pilot found ~60 s)..."

  $ok = $false
  for ($i = 0; $i -lt 60; $i++) {
    try {
      $r = Invoke-WebRequest -Uri "$Url/health" -UseBasicParsing -TimeoutSec 10 `
        -Headers @{ Authorization = "Bearer $Token" }
      if ($r.StatusCode -eq 200) { $ok = $true; break }
    } catch { }
    Start-Sleep -Seconds 2
  }
  if (-not $ok) { Die "the endpoint was not reachable through the tunnel within ~2 min" }
  Say "  verified: $Url/health returned 200 with the token."

  try {
    Invoke-WebRequest -Uri "$Url/health" -UseBasicParsing -TimeoutSec 10 | Out-Null
    Warn "without the token the endpoint answered, not 401 - check the token config."
  } catch {
    if ($_.Exception.Response.StatusCode.value__ -eq 401) {
      Say "  verified: without the token the endpoint returns 401 (token is required)."
    }
  }
}

# --- pointer (optional) ------------------------------------------------------
$PointerGist = ""
if ($Pointer -and $Url) {
  Step "Publishing a pointer gist"
  $gh = Get-Command gh -ErrorAction SilentlyContinue
  if ($gh) {
    $tmp = New-TemporaryFile
    @{ endpoint = $Url; updated = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") } |
      ConvertTo-Json -Compress | Set-Content -Encoding UTF8 $tmp
    $gistUrl = & gh gist create --public -f ptr.json $tmp 2>$null
    Remove-Item $tmp -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -eq 0 -and $gistUrl) {
      $PointerGist = ($gistUrl -split "/")[-1]
      Say "  pointer gist: $gistUrl"
      Say "  (only needed if you build a pre-configured creation; the pairing UI does not use it)"
    } else { Warn "gh gist create failed - skipping the pointer." }
  } else { Warn "gh is not installed - skipping the pointer." }
}

# --- config for the supervisor ----------------------------------------------
@"
# Written by install.ps1 - read by supervise.ps1. Contains the pairing token.
TIMELINE_BASE=$Dir
TIMELINE_PORT=$Port
TIMELINE_HOST=$BindHost
TIMELINE_CFD=$CfdBin
TIMELINE_TOKEN=$Token
POINTER_GIST=$PointerGist
"@ | Set-Content -Encoding UTF8 (Join-Path $Dir "server\config.env")

# --- supervisor (Scheduled Task, per-user, no admin) -------------------------
if (-not $NoSupervisor) {
  Step "Registering the supervisor as a Scheduled Task (every 5 min + at logon)"
  $taskName = "timeline-r1 supervisor"
  $supervise = Join-Path $Dir "server\supervise.ps1"
  $tr = "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$supervise`""
  & schtasks /Create /SC MINUTE /MO 5 /TN $taskName /TR $tr /F | Out-Null
  & schtasks /Create /SC ONLOGON /TN $taskName /TR $tr /F | Out-Null
  Say "  scheduled task '$taskName' registered (per-user; no admin)."
}

# --- next steps --------------------------------------------------------------
Step "Setup complete"
Say ""
if ($Url) { Say "  Endpoint URL : $Url" } else { Say "  Endpoint URL : (no tunnel - local only: http://${BindHost}:$Port)" }
Say "  Pairing token: $Token"
Say ""
Say "On your r1: open Timeline, bring up the pairing screen (first run, or the"
Say "'...' in the header / hold the side button), and paste:"
Say "    endpoint : $(if ($Url) { $Url } else { "http://${BindHost}:$Port" })"
Say "    token    : $Token"
Say "Tap 'test' (it should report success and a card count), then 'save'."
Say ""
Say "Verify from this machine:"
Say "    Invoke-WebRequest -Headers @{Authorization='Bearer $Token'} $(if ($Url) { $Url } else { "http://${BindHost}:$Port" })/health"
Say ""
Say "Still to do on the OS3 side - only OS3 can read your journal, recordings and"
Say "memory, so the day-cards must be produced by an OS3 scheduled task:"
Say "    In OS3, create a daily scheduled task whose prompt is the contents of"
Say "      $Dir\server\generate-timeline.md"
Say "    It writes $Dir\data\timeline.json, which this endpoint serves."
Say "    Until it runs once, the timeline is empty (health shows cardCount 0)."
Say ""
Say "Supervisor : $(if ($NoSupervisor) { 'not registered (-NoSupervisor)' } else { "Scheduled Task 'timeline-r1 supervisor'" })"
Say "Logs       : $Dir\server\endpoint.log , $Dir\server\.state\tunnel.err.log"
Say "Config     : $Dir\server\config.env  (contains the token)"
Say ""
Say "To remove everything later: stop the two processes, delete the scheduled"
Say "task ('schtasks /Delete /TN `"timeline-r1 supervisor`" /F'), and delete $Dir."
