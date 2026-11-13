# agentpro-update for Windows: brings an agentpro install up to the newest
# commit on main. claudepro.ps1 and codexpro.ps1 start it hidden at each launch,
# so the update lands for the next launch. install.ps1 copies it to
# %USERPROFILE%\.claudepro\agentpro-update.ps1.
#
# It asks GitHub at most once an hour, and does nothing when the install came
# from a clone (version "clone") or AGENTPRO_NO_UPDATE is set. After an update
# it leaves "<old> <new>" in the file "updated", which the next launch reports.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$dir = $PSScriptRoot
# Overridable for tests only.
$Api = $env:AGENTPRO_API_URL
if (-not $Api) { $Api = 'https://api.github.com/repos/beanbocchi/agentpro' }
$Raw = $env:AGENTPRO_RAW_URL
if (-not $Raw) { $Raw = 'https://raw.githubusercontent.com/beanbocchi/agentpro' }

if ($env:AGENTPRO_NO_UPDATE) { exit 0 }
$versionFile = Join-Path $dir 'version'
$version = 'unknown'
if (Test-Path $versionFile) { $version = ([System.IO.File]::ReadAllText($versionFile)).Trim() }
if ($version -eq 'clone') { exit 0 }

$stamp = Join-Path $dir 'update-checked'
if ((Test-Path $stamp) -and (Get-Item $stamp).LastWriteTime -gt (Get-Date).AddHours(-1)) { exit 0 }

# One updater at a time; a lock older than 30 minutes is left over from a crash.
$lock = Join-Path $dir 'update.lock'
if (Test-Path $lock) {
    if ((Get-Item $lock).LastWriteTime -gt (Get-Date).AddMinutes(-30)) { exit 0 }
    Remove-Item -Recurse -Force $lock
}
try { New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null } catch { exit 0 }
$tmp = $null
try {
    [System.IO.File]::WriteAllText($stamp, '')
    (Get-Item $stamp).LastWriteTime = Get-Date

    try {
        $latest = [string](Invoke-RestMethod -Uri "$Api/commits/main" -Headers @{ Accept = 'application/vnd.github.sha' } -TimeoutSec 10)
    } catch { exit 0 }
    $latest = $latest.Trim()
    if ($latest -notmatch '^[0-9a-f]{40}$' -or $latest -eq $version) { exit 0 }

    $log = Join-Path $dir 'update.log'
    "agentpro-update: $version -> $latest ($(Get-Date))" | Set-Content -Path $log
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('agentpro-update-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $installer = Join-Path $tmp 'install.ps1'
    Invoke-WebRequest -Uri "$Raw/$latest/install.ps1" -OutFile $installer -UseBasicParsing -TimeoutSec 30
    $env:AGENTPRO_REF = $latest
    $shell = (Get-Process -Id $PID).Path
    & $shell -NoProfile -ExecutionPolicy Bypass -File $installer *>> $log
    if ($LASTEXITCODE -ne 0) { exit 1 }
    [System.IO.File]::WriteAllText((Join-Path $dir 'updated'), "$version $latest")
} finally {
    Remove-Item -Recurse -Force $lock -ErrorAction SilentlyContinue
    if ($tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}
