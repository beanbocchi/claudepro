# Installs agentpro, the claudepro and codexpro commands, on Windows. Run it in
# PowerShell:
#
#   irm https://raw.githubusercontent.com/beanbocchi/agentpro/main/install.ps1 | iex
#
# It asks for the API key, checks it against the server, and writes
# %USERPROFILE%\.claudepro (url, key, launchers, /quota mod, image mod, bin\claudepro.cmd,
# bin\codexpro.cmd, and bin\claudepro and bin\codexpro for Git Bash). It adds the bin folder to the user PATH and
# installs Claude Code if `claude` is missing. Run it again to update; the
# launchers also update themselves (agentpro-update.ps1). To remove it, delete
# the folder and take its bin entry out of the user PATH.
#
# $env:CLAUDEPRO_KEY and $env:CLAUDEPRO_URL skip the prompt and the default server.
# $env:AGENTPRO_REF installs that commit instead of the newest one on main.

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    # Windows PowerShell 5.1 on older .NET does not offer TLS 1.2 to GitHub by default.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $DefaultUrl = 'http://khoakomlem-internal.ddns.net:8317'
    # Overridable for tests only.
    $Api = $env:AGENTPRO_API_URL
    if (-not $Api) { $Api = 'https://api.github.com/repos/beanbocchi/agentpro' }
    $Codeload = $env:AGENTPRO_CODELOAD_URL
    if (-not $Codeload) { $Codeload = 'https://codeload.github.com/beanbocchi/agentpro' }
    $OnWindows = $env:OS -eq 'Windows_NT'

    $UserHome = $env:USERPROFILE
    if (-not $UserHome) { $UserHome = $HOME }
    $Root = Join-Path $UserHome '.claudepro'
    $BinDir = Join-Path $Root 'bin'
    $Utf8 = New-Object System.Text.UTF8Encoding $false

    function Fail($message) { throw "claudepro install: $message" }

    # Use the files next to this script when run from a clone, else download
    # them. The version file records the commit, or "clone", which
    # agentpro-update.ps1 leaves alone so it never overwrites work in progress.
    $src = $PSScriptRoot
    $version = 'clone'
    $tmp = $null
    if (-not $src -or -not (Test-Path (Join-Path $src 'windows/claudepro.ps1'))) {
        $ref = "$env:AGENTPRO_REF".Trim()
        if (-not $ref) {
            try { $ref = ([string](Invoke-RestMethod -Uri "$Api/commits/main" -Headers @{ Accept = 'application/vnd.github.sha' } -TimeoutSec 10)).Trim() } catch { $ref = '' }
        }
        if ($ref -match '^[0-9a-f]{40}$') { $version = $ref } else { $ref = 'main'; $version = 'unknown' }
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('claudepro-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmp | Out-Null
        $zip = "$Codeload/zip/$ref"
        $zipFile = Join-Path $tmp 'src.zip'
        try { Invoke-WebRequest -Uri $zip -OutFile $zipFile -UseBasicParsing } catch { Fail "cannot download ${zip}: $($_.Exception.Message)" }
        $unpacked = Join-Path $tmp 'src'
        Expand-Archive -Path $zipFile -DestinationPath $unpacked
        # The archive holds one folder, agentpro-<ref>.
        $src = @(Get-ChildItem -Directory $unpacked)[0].FullName
    }

    try {
        $url = $env:CLAUDEPRO_URL
        $urlFile = Join-Path $Root 'url'
        if (-not $url -and (Test-Path $urlFile)) { $url = ([System.IO.File]::ReadAllText($urlFile)).Trim() }
        if (-not $url) { $url = $DefaultUrl }
        $url = $url.TrimEnd('/')

        $key = $env:CLAUDEPRO_KEY
        $keyFile = Join-Path $Root 'key'
        if (-not $key -and (Test-Path $keyFile)) {
            $key = [System.IO.File]::ReadAllText($keyFile)
            if ($key.Trim()) { Write-Host "Using the API key already in $keyFile" }
        }
        if (-not "$key".Trim()) {
            $secure = Read-Host -AsSecureString "API key for $url"
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            try { $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        }
        $key = ("$key" -replace '\s', '')
        if (-not $key) { Fail 'the API key is empty' }

        Write-Host "Checking the key against $url ..."
        try {
            $null = Invoke-RestMethod -Uri "$url/v1/models" -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 15
        } catch {
            Fail "the server rejected the key or is unreachable: $($_.Exception.Message)"
        }

        New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
        [System.IO.File]::WriteAllText($urlFile, $url, $Utf8)
        [System.IO.File]::WriteAllText($keyFile, $key, $Utf8)
        Copy-Item -Force (Join-Path $src 'windows/claudepro.ps1') (Join-Path $Root 'claudepro.ps1')
        Copy-Item -Force (Join-Path $src 'windows/codexpro.ps1') (Join-Path $Root 'codexpro.ps1')
        Copy-Item -Force (Join-Path $src 'windows/agentpro-update.ps1') (Join-Path $Root 'agentpro-update.ps1')

        # Each mod is built beside the old one and swapped in, so a running
        # session that reloads its plugin folders never finds one half copied.
        $quotaUrl = $env:CLAUDEPRO_QUOTA_URL
        if (-not $quotaUrl) { $u = [uri]$url; $quotaUrl = "$($u.Scheme)://$($u.Host):8318/quota" }
        $quota = [ordered]@{ url = $quotaUrl; keyFile = $keyFile } | ConvertTo-Json -Compress
        foreach ($name in 'image-mod', 'quota-mod') {
            $mod = Join-Path $Root $name
            $new = Join-Path $Root ".$name.new"
            $old = Join-Path $Root ".$name.old"
            foreach ($stale in $new, $old) { if (Test-Path $stale) { Remove-Item -Recurse -Force $stale } }
            Copy-Item -Recurse (Join-Path $src $name) $new
            $tests = Join-Path $new 'tests'
            if (Test-Path $tests) { Remove-Item -Recurse -Force $tests }
            if ($name -eq 'quota-mod') { [System.IO.File]::WriteAllText((Join-Path $new 'quota.json'), $quota, $Utf8) }
            if (Test-Path $mod) { Move-Item $mod $old }
            Move-Item $new $mod
            if (Test-Path $old) { Remove-Item -Recurse -Force $old }
        }
        [System.IO.File]::WriteAllText((Join-Path $Root 'version'), $version, $Utf8)

        foreach ($name in 'claudepro', 'codexpro') {
            $launcher = Join-Path $Root "$name.ps1"
            $cmdShim = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$launcher`" %*`r`n"
            [System.IO.File]::WriteAllText((Join-Path $BinDir "$name.cmd"), $cmdShim, $Utf8)
            $shShim = "#!/bin/sh`nexec powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$launcher' `"`$@`"`n"
            [System.IO.File]::WriteAllText((Join-Path $BinDir $name), $shShim, $Utf8)
        }

        if ($OnWindows) {
            $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            $parts = @("$userPath" -split ';' | Where-Object { $_ })
            if ($parts -notcontains $BinDir) {
                [Environment]::SetEnvironmentVariable('Path', (($parts + $BinDir) -join ';'), 'User')
                Write-Host "Added $BinDir to the user PATH."
            }
            if (($env:Path -split ';') -notcontains $BinDir) { $env:Path = "$env:Path;$BinDir" }

            $claudeExe = Join-Path $UserHome '.local\bin\claude.exe'
            if (-not (Get-Command claude -ErrorAction SilentlyContinue) -and -not (Test-Path $claudeExe)) {
                Write-Host 'Claude Code is not installed. Installing it ...'
                powershell -NoProfile -ExecutionPolicy Bypass -Command 'irm https://claude.ai/install.ps1 | iex'
                if (-not (Test-Path $claudeExe) -and -not (Get-Command claude -ErrorAction SilentlyContinue)) {
                    Fail 'Claude Code did not install; install it from https://claude.com/claude-code and run this again'
                }
            }
        }

        Write-Host ''
        Write-Host "Installed $Root" -ForegroundColor Green
        Write-Host 'Open a new terminal (cmd, PowerShell or Git Bash) and run: claudepro'
        Write-Host 'claudepro runs Claude Code, Claude models first; /quota inside it shows the accounts'' plan limits.'
        Write-Host 'codexpro runs Codex CLI, GPT models first.'
        if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
            Write-Host 'codexpro needs Codex CLI, which is not installed: https://github.com/openai/codex'
        }
    } finally {
        if ($tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }
}
