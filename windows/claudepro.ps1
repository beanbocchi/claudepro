# claudepro launcher for Windows. install.ps1 copies it to
# %USERPROFILE%\.claudepro\claudepro.ps1, and bin\claudepro.cmd runs it.
#
# The server URL is in the url file next to this script and the API key in the
# key file. CLAUDEPRO_BASE_URL and CLAUDEPRO_AUTH_TOKEN override them, and
# CLAUDEPRO_MODEL picks a model for one run. The server sets the default model
# with a claudepro-default.<model> alias.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Fail($message, $code = 1) {
    [Console]::Error.WriteLine("claudepro: $message")
    exit $code
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

$defaultPrefix = 'claudepro-default.'
$aliases = New-Object System.Collections.Generic.List[string]
$options = New-Object System.Collections.Generic.List[object]
$seen = @{}
foreach ($item in @($catalog.data)) {
    $id = [string]$item.id
    if (-not $id -or $id.Trim() -ne $id -or $seen.ContainsKey($id)) { continue }
    $seen[$id] = $true
    if ($id.StartsWith($defaultPrefix)) { $aliases.Add($id); continue }
    $lower = $id.ToLower()
    $behavesAs = 'claude-opus-5-5'
    if ($lower.Contains('haiku')) { $behavesAs = 'claude-haiku-5-5' }
    elseif ($lower.Contains('sonnet')) { $behavesAs = 'claude-sonnet-5-5' }
    $option = [ordered]@{ model = $id; label = $id; behavesAs = $behavesAs }
    $owner = [string]$item.owned_by
    if (-not $owner) { $owner = [string]$item.description }
    if ($owner) { $option['description'] = $owner }
    $options.Add($option)
}
if ($options.Count -eq 0) { Fail 'proxy returned an empty model list' }

$ids = @($options | ForEach-Object { $_.model })
$serverDefault = $null
foreach ($alias in $aliases) {
    $target = $alias.Substring($defaultPrefix.Length)
    if ($ids -contains $target) { $serverDefault = $target; break }
}
$requested = "$env:CLAUDEPRO_MODEL".Trim()
if ($requested) {
    if ($ids -notcontains $requested) { Fail "CLAUDEPRO_MODEL is not in the proxy catalog: $requested" }
    $model = $requested
} elseif ($serverDefault) {
    $model = $serverDefault
} elseif ($ids -contains 'claude-opus-5-5') {
    $model = 'claude-opus-5-5'
} elseif ($ids -contains 'gpt-6-luna') {
    $model = 'gpt-6-luna'
} else {
    $pool = @($ids | Where-Object { -not $_.ToLower().Contains('image') })
    if ($pool.Count -eq 0) { $pool = $ids }
    $model = @($pool | Sort-Object)[0]
    [Console]::Error.WriteLine("claudepro: the server sets no default and claude-opus-5-5 and gpt-6-luna are unavailable; defaulting to $model")
}

$settings = [ordered]@{
    model = $model
    modelPicker = [ordered]@{ options = [object[]]$options.ToArray(); replaceBuiltInOptions = $true }
}
# One file per model, kept after exit: background jobs read it again later.
$settingsFile = Join-Path $PSScriptRoot ("settings-" + ($model -replace '[^A-Za-z0-9._-]', '_') + ".json")
[System.IO.File]::WriteAllText($settingsFile, ($settings | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding $false))

$env:ANTHROPIC_BASE_URL = $baseUrl
$env:ANTHROPIC_AUTH_TOKEN = $token
Remove-Item Env:ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
$env:ANTHROPIC_MODEL = $model
$env:CLAUDE_CODE_SUBAGENT_MODEL = $model

$claude = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($claude) { $claudeExe = $claude.Source } else { $claudeExe = Join-Path $env:USERPROFILE '.local\bin\claude.exe' }
if (-not (Test-Path $claudeExe)) { Fail 'Claude Code (claude) is not installed; run install.ps1 again' }

& $claudeExe --dangerously-skip-permissions --settings $settingsFile --plugin-dir (Join-Path $PSScriptRoot 'quota-mod') @args
exit $LASTEXITCODE
