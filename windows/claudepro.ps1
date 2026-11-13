# claudepro launcher for Windows. install.ps1 copies it to
# %USERPROFILE%\.claudepro\claudepro.ps1, and bin\claudepro.cmd runs it.
#
# The server URL is in the url file next to this script and the API key in the
# key file. CLAUDEPRO_BASE_URL and CLAUDEPRO_AUTH_TOKEN override them, and
# CLAUDEPRO_MODEL picks a model for one run. The server can pin a model with a
# claudepro-default.<model> alias; otherwise none is pinned. The /model picker lists every chat
# model the server offers, Claude models first.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Fail($message, $code = 1) {
    [Console]::Error.WriteLine("claudepro: $message")
    exit $code
}

# Report an update the last launch installed, then look for the next one in a
# hidden background process (agentpro-update.ps1); this launch does not wait.
$updatedFile = Join-Path $PSScriptRoot 'updated'
if (Test-Path $updatedFile) {
    $parts = @(([System.IO.File]::ReadAllText($updatedFile)).Trim() -split '\s+') + @('', '')
    $short = $parts | ForEach-Object { if ($_.Length -gt 7) { $_.Substring(0, 7) } else { $_ } }
    [Console]::Error.WriteLine("agentpro: updated to $($short[1]) (was $($short[0]))")
    Remove-Item -Force $updatedFile
}
$updater = Join-Path $PSScriptRoot 'agentpro-update.ps1'
if (Test-Path $updater) {
    $start = @{
        FilePath = (Get-Process -Id $PID).Path
        ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$updater`"")
    }
    if ($env:OS -eq 'Windows_NT') { $start.WindowStyle = 'Hidden' }
    try { Start-Process @start | Out-Null } catch { }
}

foreach ($arg in $args) {
    if ($arg -eq '--permission-mode' -or "$arg" -like '--permission-mode=*') {
        Fail 'permission mode is fixed to bypassPermissions' 2
    }
}

function Read-Setting($name) {
    $path = Join-Path $PSScriptRoot $name
    if (-not (Test-Path $path)) { Fail "cannot read $path; run install.ps1 again" }
    return ([System.IO.File]::ReadAllText($path)).Trim()
}

$baseUrl = $env:CLAUDEPRO_BASE_URL
if (-not $baseUrl) { $baseUrl = Read-Setting 'url' }
$baseUrl = $baseUrl.TrimEnd('/')
$token = $env:CLAUDEPRO_AUTH_TOKEN
if (-not $token) { $token = Read-Setting 'key' }
if (-not $token) { Fail 'the API key is empty' }

try {
    $catalog = Invoke-RestMethod -Uri "$baseUrl/v1/models" -Headers @{ Authorization = "Bearer $token"; Accept = 'application/json' } -TimeoutSec 10
} catch {
    Fail "cannot reach proxy: $($_.Exception.Message)"
}

# Models neither harness can talk to: image, audio and video generation,
# embeddings, and Codex's internal reviewer. Keep in step with lib/claudepro-settings.
$Unusable = 'image', 'video', 'audio', 'tts', 'embed', 'transcri', 'realtime', 'moderation', 'dall-e', 'sora', 'whisper', 'auto-review'
# Lines within a family, largest first. GPT names grow from luna (moon) to astra (stars).
$TierNames = @{ claude = @('fable', 'opus', 'sonnet', 'haiku'); gpt = @('astra', 'sol', 'terra', 'luna') }

function Get-Family($id, $owner) {
    if ($owner -eq 'anthropic' -or $id.StartsWith('claude-')) { return 'claude' }
    if ($id.StartsWith('gpt-')) { return 'gpt' }
    return 'other'
}

function Test-Usable($id) {
    $lower = $id.ToLower()
    foreach ($word in $Unusable) { if ($lower.Contains($word)) { return $false } }
    return $true
}

# Family (the launcher's own first), then generation (major version), then
# tier, then the newer minor version. Eight-digit dates are not versions.
function Get-SortKey($id, $owner, $first) {
    $family = Get-Family $id $owner
    $words = $id.ToLower().Replace('.', '-').Split('-')
    $numbers = @($words | Where-Object { $_ -match '^\d{1,7}$' } | ForEach-Object { [int]$_ }) + @(0, 0)
    $lineup = @()
    if ($TierNames.ContainsKey($family)) { $lineup = $TierNames[$family] }
    $tier = $lineup.Count
    for ($i = 0; $i -lt $lineup.Count; $i++) { if ($words -contains $lineup[$i]) { $tier = $i; break } }
    $rank = 2
    if ($family -eq $first) { $rank = 0 } elseif ($TierNames.ContainsKey($family)) { $rank = 1 }
    return '{0}{1:D4}{2:D2}{3:D4}{4}' -f $rank, (9999 - $numbers[0]), $tier, (9999 - $numbers[1]), $id
}

$defaultPrefix = 'claudepro-default.'
$aliases = New-Object System.Collections.Generic.List[string]
$options = New-Object System.Collections.Generic.List[object]
$seen = @{}
foreach ($item in @($catalog.data)) {
    $id = [string]$item.id
    if (-not $id -or $id.Trim() -ne $id -or $seen.ContainsKey($id)) { continue }
    $seen[$id] = $true
    if ($id.StartsWith($defaultPrefix)) { $aliases.Add($id); continue }
    if ($id.StartsWith('codexpro-default.') -or -not (Test-Usable $id)) { continue }
    $owner = [string]$item.owned_by
    $sortKey = Get-SortKey $id $owner 'claude'
    $lower = $id.ToLower()
    $behavesAs = 'claude-opus-5-5'
    if ($lower.Contains('haiku')) { $behavesAs = 'claude-haiku-5-5' }
    elseif ($lower.Contains('sonnet')) { $behavesAs = 'claude-sonnet-5-5' }
    $option = [ordered]@{ model = $id; label = $id; behavesAs = $behavesAs }
    if (-not $owner) { $owner = [string]$item.description }
    if ($owner) { $option['description'] = $owner }
    $options.Add([pscustomobject]@{ key = $sortKey; option = $option })
}
if ($options.Count -eq 0) { Fail 'the proxy lists no chat models' }
$options = @($options | Sort-Object { $_.key } | ForEach-Object { $_.option })

$ids = @($options | ForEach-Object { $_.model })
$serverDefault = $null
foreach ($alias in $aliases) {
    $target = $alias.Substring($defaultPrefix.Length)
    if ($ids -contains $target) { $serverDefault = $target; break }
}
# A model is pinned only when CLAUDEPRO_MODEL or the server's alias names one.
$requested = "$env:CLAUDEPRO_MODEL".Trim()
$model = $null
if ($requested) {
    if ($ids -notcontains $requested) { Fail "CLAUDEPRO_MODEL is not a chat model in the proxy catalog: $requested" }
    $model = $requested
} elseif ($serverDefault) {
    $model = $serverDefault
}

# The built-in rows (Default, Opus, Sonnet, ...) stay: their aliases move to the
# newest model with each Claude Code release. Claude Code skips a listed model a
# built-in row already covers.
$settings = [ordered]@{}
if ($model) { $settings['model'] = $model }
$settings['modelPicker'] = [ordered]@{ options = [object[]]$options; replaceBuiltInOptions = $false }
# One file per pinned model (settings-default.json when none), kept after exit:
# background jobs read it again later.
$name = 'default'
if ($model) { $name = $model }
$settingsFile = Join-Path $PSScriptRoot ("settings-" + ($name -replace '[^A-Za-z0-9._-]', '_') + ".json")
[System.IO.File]::WriteAllText($settingsFile, ($settings | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding $false))

$env:ANTHROPIC_BASE_URL = $baseUrl
$env:ANTHROPIC_AUTH_TOKEN = $token
Remove-Item Env:ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
# With no pin, Claude Code starts on its own default or the /model choice saved
# in ~/.claude/settings.json, and subagents pick their own. Values left over from
# a claudepro session this one was started from are cleared too.
Remove-Item Env:CLAUDE_CODE_SUBAGENT_MODEL -ErrorAction SilentlyContinue
if ($model) { $env:ANTHROPIC_MODEL = $model } else { Remove-Item Env:ANTHROPIC_MODEL -ErrorAction SilentlyContinue }

$claude = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($claude) { $claudeExe = $claude.Source } else { $claudeExe = Join-Path $env:USERPROFILE '.local\bin\claude.exe' }
if (-not (Test-Path $claudeExe)) { Fail 'Claude Code (claude) is not installed; run install.ps1 again' }

& $claudeExe --dangerously-skip-permissions --settings $settingsFile --plugin-dir (Join-Path $PSScriptRoot 'quota-mod') --plugin-dir (Join-Path $PSScriptRoot 'image-mod') @args
exit $LASTEXITCODE
