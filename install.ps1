# Installs agentpro, the claudepro and codexpro commands, on Windows. Run it in
# PowerShell:
#
#   irm https://raw.githubusercontent.com/beanbocchi/agentpro/main/install.ps1 | iex
#
# It asks for the API key, checks it against the server, and writes
# %USERPROFILE%\.claudepro (url, key, launchers, /quota mod, image mod, bin\claudepro.cmd,
# bin\codexpro.cmd, and bin\claudepro and bin\codexpro for Git Bash). It adds the bin folder to the user PATH and
# installs Claude Code if `claude` is missing. Run it again to update. To remove
# it, delete the folder and take its bin entry out of the user PATH.
#
# $env:CLAUDEPRO_KEY and $env:CLAUDEPRO_URL skip the prompt and the default server.

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    # Windows PowerShell 5.1 on older .NET does not offer TLS 1.2 to GitHub by default.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $DefaultUrl = 'http://khoakomlem-internal.ddns.net:8317'
    $Zip = 'https://codeload.github.com/beanbocchi/agentpro/zip/refs/heads/main'
    $OnWindows = $env:OS -eq 'Windows_NT'

    $UserHome = $env:USERPROFILE
    if (-not $UserHome) { $UserHome = $HOME }
    $Root = Join-Path $UserHome '.claudepro'
    $BinDir = Join-Path $Root 'bin'
    $Utf8 = New-Object System.Text.UTF8Encoding $false

    function Fail($message) { throw "claudepro install: $message" }

    # Use the files next to this script when run from a clone, else download them.
    $src = $PSScriptRoot
    $tmp = $null
    if (-not $src -or -not (Test-Path (Join-Path $src 'windows/claudepro.ps1'))) {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('claudepro-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmp | Out-Null
        $zipFile = Join-Path $tmp 'src.zip'
        try { Invoke-WebRequest -Uri $Zip -OutFile $zipFile -UseBasicParsing } catch { Fail "cannot download ${Zip}: $($_.Exception.Message)" }
        Expand-Archive -Path $zipFile -DestinationPath $tmp
        $src = Join-Path $tmp 'agentpro-main'
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

        $mod = Join-Path $Root 'quota-mod'
        if (Test-Path $mod) { Remove-Item -Recurse -Force $mod }
        Copy-Item -Recurse (Join-Path $src 'quota-mod') $mod
        $tests = Join-Path $mod 'tests'
        if (Test-Path $tests) { Remove-Item -Recurse -Force $tests }
        $quotaUrl = $env:CLAUDEPRO_QUOTA_URL
        if (-not $quotaUrl) { $u = [uri]$url; $quotaUrl = "$($u.Scheme)://$($u.Host):8318/quota" }
        $quota = [ordered]@{ url = $quotaUrl; keyFile = $keyFile } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText((Join-Path $mod 'quota.json'), $quota, $Utf8)

        $imageMod = Join-Path $Root 'image-mod'
        if (Test-Path $imageMod) { Remove-Item -Recurse -Force $imageMod }
        Copy-Item -Recurse (Join-Path $src 'image-mod') $imageMod
        $imageTests = Join-Path $imageMod 'tests'
        if (Test-Path $imageTests) { Remove-Item -Recurse -Force $imageTests }

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
