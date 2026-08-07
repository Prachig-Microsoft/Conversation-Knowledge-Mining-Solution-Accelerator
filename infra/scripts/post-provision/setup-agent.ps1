#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Set up the Azure AI Foundry agent after deployment.
.DESCRIPTION
    Creates the KnowledgeMiningAgent in Azure AI Foundry with Azure AI Search as
    a tool. Configuration is resolved, in order of precedence: 1) explicit
    parameters, 2) the azd environment, 3) the LIVE app settings of the target
    API App Service (auto-discovered from -ResourceGroupName for non-azd /
    AVM-based deployments). Reading live app settings (rather than relying on
    the root .env file) avoids accidentally using stale values left over from a
    previously deployed resource group. After the agent is created, the freshly
    generated AGENT_NAME_CHAT / AGENT_NAME_TITLE / USE_SQL / DATA_SOURCE_TYPE
    settings (read from data/config/agent_ids.json, which create_agent.py always
    writes regardless of azd) are pushed back to that same API App Service.
.PARAMETER Scenario
    Scenario key from data/config/scenarios.json used to generate the agent prompt.
.PARAMETER ResourceGroupName
    Name of the resource group the solution was deployed into. Required when not
    using azd (also used for auto-discovery of the API App Service and its live
    configuration).
.PARAMETER ApiAppName
    Name of the API App Service. Auto-discovered from the resource group when
    omitted (matches an app whose name starts with "api-").
.EXAMPLE
    ./infra/scripts/post-provision/setup-agent.ps1 -Scenario contact-center
.EXAMPLE
    # AVM / non-azd deployment (API App Service auto-discovered from the resource group)
    ./infra/scripts/post-provision/setup-agent.ps1 -Scenario contact-center -ResourceGroupName "my-rg"
#>

param(
    [string]$Scenario,
    [string]$ResourceGroupName,
    [string]$ApiAppName
)

$azdAvailable = [bool](Get-Command azd -ErrorAction SilentlyContinue)

function Get-AzdEnvValue {
    param([string]$Name)
    if (-not $azdAvailable) { return "" }
    $value = azd env get-value $Name 2>$null
    if (-not $value) { return "" }
    if ($value -is [string] -and $value.StartsWith("ERROR:")) { return "" }
    return "$value".Trim()
}

# ── Auto-discovery helpers (non-azd / AVM-based deployments) ──
function Get-DiscoveredWebAppName([string]$rg, [string]$prefix) {
    if (-not $rg) { return "" }
    $names = (az webapp list --resource-group $rg --query "[].name" -o tsv 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $names) { return "" }
    return (($names -split "`n") | Where-Object { $_ -like "$prefix*" } | Select-Object -First 1).Trim()
}

function Get-AppSetting([string]$appName, [string]$rg, [string]$settingName) {
    if (-not $appName -or -not $rg) { return "" }
    $val = (az webapp config appsettings list --name $appName --resource-group $rg --query "[?name=='$settingName'].value | [0]" -o tsv 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $val -or $val -eq "None") { return "" }
    return "$val".Trim()
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Knowledge Mining - Agent Setup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ── Resolve resource group / API App Service: explicit params, then azd env, then auto-discovery ──
$resourceGroup = if ($ResourceGroupName) { $ResourceGroupName } else { Get-AzdEnvValue -Name "RESOURCE_GROUP_NAME" }
if (-not $resourceGroup) { $resourceGroup = Get-AzdEnvValue -Name "AZURE_RESOURCE_GROUP" }

$apiAppName = if ($ApiAppName) { $ApiAppName } else { Get-AzdEnvValue -Name "API_APP_NAME" }
if (-not $apiAppName -and $resourceGroup) { $apiAppName = Get-DiscoveredWebAppName $resourceGroup "api-" }

# ── Pull LIVE configuration from the target API App Service so agent creation
#    always targets THIS resource group's AI Foundry project/search, never a
#    stale root .env left over from a different (previously deployed) RG. ──
if ($resourceGroup -and $apiAppName) {
    Write-Host "Reading live configuration from API App Service '$apiAppName' ($resourceGroup)..." -ForegroundColor Yellow
    $liveSettings = [ordered]@{
        AZURE_AI_AGENT_ENDPOINT         = Get-AppSetting $apiAppName $resourceGroup "AZURE_AI_AGENT_ENDPOINT"
        AZURE_AI_SEARCH_CONNECTION_NAME = Get-AppSetting $apiAppName $resourceGroup "AZURE_AI_SEARCH_CONNECTION_NAME"
        AZURE_SEARCH_INDEX_NAME         = Get-AppSetting $apiAppName $resourceGroup "AZURE_SEARCH_INDEX_NAME"
        AZURE_OPENAI_CHAT_DEPLOYMENT    = Get-AppSetting $apiAppName $resourceGroup "AZURE_OPENAI_CHAT_DEPLOYMENT"
        SOLUTION_SUFFIX                 = Get-AppSetting $apiAppName $resourceGroup "SOLUTION_SUFFIX"
    }
    foreach ($key in $liveSettings.Keys) {
        if ($liveSettings[$key]) { Set-Item -Path "env:$key" -Value $liveSettings[$key] }
    }
    if (-not $liveSettings["AZURE_AI_AGENT_ENDPOINT"]) {
        Write-Host "  [WARN] Could not read AZURE_AI_AGENT_ENDPOINT from '$apiAppName'. Falling back to .env / azd env." -ForegroundColor Yellow
    } else {
        Write-Host "  [OK] Using AZURE_AI_AGENT_ENDPOINT=$($liveSettings['AZURE_AI_AGENT_ENDPOINT'])" -ForegroundColor Green
    }
} else {
    Write-Host "No -ResourceGroupName/-ApiAppName resolved; falling back to .env / azd env values." -ForegroundColor Yellow
}

$envFile = Join-Path $PSScriptRoot ".." ".." ".." ".env"
if (-not (Test-Path $envFile) -and -not $env:AZURE_AI_AGENT_ENDPOINT) {
    Write-Host "WARNING: .env file not found. Trying azd env values..." -ForegroundColor Yellow

    # Try to get values from azd
    $endpoint = Get-AzdEnvValue -Name "AZURE_AI_AGENT_ENDPOINT"
    if (-not $endpoint) {
        Write-Host "ERROR: AZURE_AI_AGENT_ENDPOINT not set." -ForegroundColor Red
        Write-Host "Set it in .env, pass -ResourceGroupName, or run: azd env set AZURE_AI_AGENT_ENDPOINT <value>" -ForegroundColor Yellow
        exit 1
    }
}

# Activate venv if available
$venvPath = Join-Path $PSScriptRoot ".." ".." ".." "venv" "Scripts" "Activate.ps1"
if (Test-Path $venvPath) {
    & $venvPath
}

Write-Host "Generating scenario-based agent prompt..." -ForegroundColor Yellow
$genArgs = @()
if ($Scenario) { $genArgs += @("--scenario", $Scenario) }
python (Join-Path $PSScriptRoot "generate_agent_prompt.py") @genArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host "Prompt generation failed." -ForegroundColor Red
    exit 1
}

Write-Host "Creating agents..." -ForegroundColor Yellow
$createArgs = @()
if ($Scenario) { $createArgs += @("--scenario", $Scenario) }
python (Join-Path $PSScriptRoot "create_agent.py") @createArgs

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "Agent created successfully!" -ForegroundColor Green
    Write-Host ""

    # Push the freshly created agent settings to the API App Service so the
    # running backend picks up AGENT_NAME_CHAT / AGENT_NAME_TITLE / USE_SQL.
    # Re-resolve in case the earlier auto-discovery didn't find them (e.g. .env
    # only), but reuse $resourceGroup/$apiAppName already resolved above first.
    if (-not $apiAppName)    { $apiAppName    = Get-AzdEnvValue -Name "API_APP_NAME" }
    if (-not $resourceGroup) { $resourceGroup = Get-AzdEnvValue -Name "RESOURCE_GROUP_NAME" }
    if (-not $resourceGroup) { $resourceGroup = Get-AzdEnvValue -Name "AZURE_RESOURCE_GROUP" }
    if (-not $apiAppName -and $resourceGroup) { $apiAppName = Get-DiscoveredWebAppName $resourceGroup "api-" }

    # create_agent.py always writes data/config/agent_ids.json with the
    # authoritative agent settings, regardless of azd availability - read from
    # there instead of azd env (which is never populated for non-azd deployments).
    $agentIdsPath = Join-Path $PSScriptRoot ".." ".." ".." "data" "config" "agent_ids.json"
    $agentNameChat = $agentNameTitle = $useSql = $dataSourceType = ""
    if (Test-Path $agentIdsPath) {
        $agentIds       = Get-Content $agentIdsPath -Raw | ConvertFrom-Json
        $agentNameChat  = "$($agentIds.chat_agent_name)"
        $agentNameTitle = "$($agentIds.title_agent_name)"
        $useSql         = "$($agentIds.use_sql)".ToLower()
        $dataSourceType = "$($agentIds.data_source_type)"
    } else {
        Write-Host "  [WARN] data/config/agent_ids.json not found; falling back to azd env for settings push." -ForegroundColor Yellow
        $agentNameChat  = Get-AzdEnvValue -Name "AGENT_NAME_CHAT"
        $agentNameTitle = Get-AzdEnvValue -Name "AGENT_NAME_TITLE"
        $useSql         = Get-AzdEnvValue -Name "USE_SQL"
        $dataSourceType = Get-AzdEnvValue -Name "DATA_SOURCE_TYPE"
    }

    if ($apiAppName -and $resourceGroup -and $agentNameChat) {
        Write-Host "Updating API App Service '$apiAppName' agent settings..." -ForegroundColor Yellow
        az webapp config appsettings set `
            --name $apiAppName `
            --resource-group $resourceGroup `
            --settings "AGENT_NAME_CHAT=$agentNameChat" "AGENT_NAME_TITLE=$agentNameTitle" "USE_SQL=$useSql" "DATA_SOURCE_TYPE=$dataSourceType" `
            --output none
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] App Service settings updated (AGENT_NAME_CHAT=$agentNameChat, AGENT_NAME_TITLE=$agentNameTitle, USE_SQL=$useSql, DATA_SOURCE_TYPE=$dataSourceType)" -ForegroundColor Green
        } else {
            Write-Host "  [WARN] Failed to update App Service settings" -ForegroundColor Yellow
            $global:LASTEXITCODE = 0
        }
    } else {
        Write-Host "  [SKIP] API_APP_NAME / RESOURCE_GROUP_NAME / agent settings could not be resolved (pass -ResourceGroupName or -ApiAppName explicitly)" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Test it:" -ForegroundColor Yellow
    Write-Host "  python infra/scripts/utilities/test_agent.py"
    Write-Host "  python infra/scripts/utilities/test_agent.py -v  (verbose mode)"
    Write-Host ""
} else {
    Write-Host "Agent creation failed." -ForegroundColor Red
    exit 1
}
