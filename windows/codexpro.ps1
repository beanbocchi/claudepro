# codexpro launcher for Windows: Codex CLI through the claudepro server, GPT
# models first. install.ps1 copies it to %USERPROFILE%\.claudepro\codexpro.ps1,
# and bin\codexpro.cmd runs it.
#
# It reads the url and key files next to this script, as claudepro does, and the
# same CLAUDEPRO_BASE_URL and CLAUDEPRO_AUTH_TOKEN overrides. CODEXPRO_MODEL
# picks a model for one run, and the server can pin one with a
# codexpro-default.<model> alias; otherwise Codex starts on its own default. Codex keeps its config, sessions and logs in
# the codex-home folder next to this script, apart from %USERPROFILE%\.codex.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Fail($message, $code = 1) {
    [Console]::Error.WriteLine("codexpro: $message")
    exit $code
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

$codex = Get-Command codex -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $codex) { Fail 'Codex CLI (codex) is not installed; see https://github.com/openai/codex' }

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

$defaultPrefix = 'codexpro-default.'
$aliases = New-Object System.Collections.Generic.List[string]
$found = New-Object System.Collections.Generic.List[object]
$seen = @{}
foreach ($item in @($catalog.data)) {
    $id = [string]$item.id
    if (-not $id -or $id.Trim() -ne $id -or $seen.ContainsKey($id)) { continue }
    $seen[$id] = $true
    if ($id.StartsWith($defaultPrefix)) { $aliases.Add($id); continue }
    if ($id.StartsWith('claudepro-default.') -or -not (Test-Usable $id)) { continue }
    $owner = [string]$item.owned_by
    $found.Add([pscustomobject]@{ id = $id; owner = $owner; key = (Get-SortKey $id $owner 'gpt') })
}
if ($found.Count -eq 0) { Fail 'the proxy lists no chat models' }
$models = @($found | Sort-Object { $_.key })
$ids = @($models | ForEach-Object { $_.id })

$serverDefault = $null
foreach ($alias in $aliases) {
    $target = $alias.Substring($defaultPrefix.Length)
    if ($ids -contains $target) { $serverDefault = $target; break }
}
# A model is pinned only when CODEXPRO_MODEL or the server's alias names one.
$requested = "$env:CODEXPRO_MODEL".Trim()
$model = $null
if ($requested) {
    if ($ids -notcontains $requested) { Fail "CODEXPRO_MODEL is not a chat model in the proxy catalog: $requested" }
    $model = $requested
} elseif ($serverDefault) {
    $model = $serverDefault
}

$env:CODEX_HOME = Join-Path $PSScriptRoot 'codex-home'
New-Item -ItemType Directory -Force -Path $env:CODEX_HOME | Out-Null

# /model lists the server's models from models.json. A GPT model the installed
# Codex ships keeps its own entry. Any other model gets a copy of gpt-5.5's entry
# (the last one without GPT-only tool modes); a Claude model also has what only
# OpenAI's servers offer turned off. Keep in step with lib/claudepro-settings.
$bundledText = & $codex.Source debug models --bundled 2>$null | Out-String
if ($LASTEXITCODE -ne 0 -or -not $bundledText.Trim()) { Fail '`codex debug models --bundled` failed; update Codex CLI' }
$shipped = @{}
foreach ($entry in @(($bundledText | ConvertFrom-Json).models)) { if ($entry.slug) { $shipped[[string]$entry.slug] = $entry } }
$template = $shipped['gpt-5.5']
if (-not $template) { $template = @($shipped.Values)[0] }
if (-not $template) { Fail 'codex debug models printed no models' }
$claudeOverrides = [ordered]@{
    tool_mode = $null; use_responses_lite = $false; service_tiers = @(); additional_speed_tiers = @()
    availability_nux = $null; upgrade = $null; experimental_supported_tools = @(); multi_agent_version = $null
    supports_search_tool = $false; support_verbosity = $false; context_window = 200000; max_context_window = 200000
    default_reasoning_level = 'medium'
}
$entries = New-Object System.Collections.Generic.List[object]
$priority = 0
foreach ($m in $models) {
    $priority++
    if ($shipped.ContainsKey($m.id)) {
        $entry = $shipped[$m.id].PSObject.Copy()
    } else {
        $entry = $template.PSObject.Copy()
        $owner = $m.owner
        if (-not $owner) { $owner = 'Model' }
        $entry | Add-Member -Force slug $m.id
        $entry | Add-Member -Force display_name $m.id
        $entry | Add-Member -Force description "$owner on the claudepro server"
        $entry.PSObject.Properties.Remove('comp_hash')
        if ((Get-Family $m.id $m.owner) -ne 'gpt') {
            foreach ($name in $claudeOverrides.Keys) { $entry | Add-Member -Force $name $claudeOverrides[$name] }
            $levels = @($template.supported_reasoning_levels | Where-Object { @('low', 'medium', 'high') -contains $_.effort })
            $entry | Add-Member -Force supported_reasoning_levels $levels
        }
    }
    $entry | Add-Member -Force priority $priority
    $entry | Add-Member -Force visibility 'list'
    $entries.Add($entry)
}
$catalogFile = Join-Path $env:CODEX_HOME 'models.json'
$catalogJson = [ordered]@{ models = [object[]]$entries.ToArray() } | ConvertTo-Json -Depth 32 -Compress
[System.IO.File]::WriteAllText($catalogFile, $catalogJson, (New-Object System.Text.UTF8Encoding $false))

# Codex starts on the lowest priority of the catalog it reads, which would be the
# first model of the reordered one. Unless /model saved a choice in config.toml,
# pass the model Codex itself would start on: the listed shipped model with the
# lowest priority among those the server offers.
if (-not $model) {
    $configFile = Join-Path $env:CODEX_HOME 'config.toml'
    $saved = $false
    if (Test-Path $configFile) {
        foreach ($line in [System.IO.File]::ReadAllLines($configFile)) {
            $line = $line.Trim()
            if ($line.StartsWith('[')) { break }
            if ($line -match '^model\s*=') { $saved = $true; break }
        }
    }
    if (-not $saved) {
        $own = @($shipped.Values | Where-Object { $ids -contains [string]$_.slug -and $_.visibility -eq 'list' } | Sort-Object { [int]$_.priority })
        if ($own.Count -gt 0) { $model = [string]$own[0].slug } else { $model = $ids[0] }
    }
}
$pick = @()
if ($model) { $pick = @('-c', "model=`"$model`"") }

$env:CLAUDEPRO_AUTH_TOKEN = $token

# Codex sends CLAUDEPRO_AUTH_TOKEN as the bearer token (env_key). These run in
# front of any subcommand, so `codexpro exec ...` and `codexpro resume` get them
# too; -m on the command line still picks another model.
$provider = "model_providers.claudepro={name=`"claudepro`", base_url=`"$baseUrl/v1`", env_key=`"CLAUDEPRO_AUTH_TOKEN`", wire_api=`"responses`"}"
& $codex.Source -c model_provider=claudepro -c $provider @pick -c "model_catalog_json='$catalogFile'" -c approval_policy=never -c sandbox_mode=danger-full-access @args
exit $LASTEXITCODE
