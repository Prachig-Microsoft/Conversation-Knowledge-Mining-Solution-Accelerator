#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Grant the backend API's managed identity access to Azure SQL.
.DESCRIPTION
    Reads the SQL server/database and the API managed identity, then creates a
    contained database user and assigns db_datareader / db_datawriter /
    db_ddladmin. Runs as the deployer (Azure CLI credentials), who must be the
    SQL Azure AD admin. Configuration is resolved, in order of precedence, from:
    1) explicit parameters, 2) the azd environment (AZURE_SQL_SERVER,
    AZURE_SQL_DATABASE, API_APP_NAME, AZURE_API_PRINCIPAL_ID) when azd is
    available, 3) auto-discovery from the resource group (for non-azd /
    AVM-based deployments) - the SQL server/database are discovered assuming a
    single server/database in the group, and the API App Service is discovered
    by its 'api-' name prefix.
.PARAMETER ResourceGroupName
    Name of the resource group the solution was deployed into. Required when not
    using azd (also used for auto-discovery of the SQL server/database/App Service).
.PARAMETER SqlServerName
    Fully qualified name of the Azure SQL server (e.g. "myserver.database.windows.net").
    Auto-discovered from the resource group when omitted (assumes a single SQL
    server in the group).
.PARAMETER SqlDatabaseName
    Name of the Azure SQL database. Auto-discovered from the resource group when
    omitted (assumes a single non-master database in the group).
.PARAMETER ApiAppName
    Name of the API App Service. Auto-discovered from the resource group when
    omitted (matches an app whose name starts with "api-").
.PARAMETER PrincipalId
    Principal (object) ID of the API App Service's managed identity. Looked up
    via the Azure CLI from -ApiAppName / -ResourceGroupName when omitted.
.EXAMPLE
    # azd-based deployment (values resolved automatically from azd environment)
    ./infra/scripts/post-provision/setup-sql-roles.ps1
.EXAMPLE
    # AVM / non-azd deployment (SQL server/database/App Service auto-discovered)
    ./infra/scripts/post-provision/setup-sql-roles.ps1 -ResourceGroupName "my-rg"
.EXAMPLE
    # AVM / non-azd deployment (explicit parameters)
    ./infra/scripts/post-provision/setup-sql-roles.ps1 `
        -ResourceGroupName "my-rg" `
        -SqlServerName "myserver.database.windows.net" `
        -SqlDatabaseName "mydb" `
        -ApiAppName "app-abc123-api"
#>

param(
    [string]$ResourceGroupName,
    [string]$SqlServerName,
    [string]$SqlDatabaseName,
    [string]$ApiAppName,
    [string]$PrincipalId
)

$ErrorActionPreference = "Stop"

$azdAvailable = [bool](Get-Command azd -ErrorAction SilentlyContinue)

function Get-AzdValue([string]$key) {
    if (-not $azdAvailable) { return "" }
    $val = (azd env get-value $key 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $val -or $val -match 'ERROR|not found') { return "" }
    return $val.Trim()
}

# ── Auto-discovery helpers (non-azd / AVM-based deployments): resolve names from the
#    resource group when not supplied explicitly and not available via azd. ──
function Get-DiscoveredSqlServerName([string]$rg) {
    if (-not $rg) { return "" }
    $names = (az sql server list --resource-group $rg --query "[].fullyQualifiedDomainName" -o tsv 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $names) { return "" }
    return (($names -split "`n") | Where-Object { $_ } | Select-Object -First 1).Trim()
}

function Get-DiscoveredSqlDatabaseName([string]$rg, [string]$serverShortName) {
    if (-not $rg -or -not $serverShortName) { return "" }
    $names = (az sql db list --resource-group $rg --server $serverShortName --query "[?name!='master'].name" -o tsv 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $names) { return "" }
    return (($names -split "`n") | Where-Object { $_ } | Select-Object -First 1).Trim()
}

function Get-DiscoveredWebAppName([string]$rg, [string]$prefix) {
    if (-not $rg) { return "" }
    $names = (az webapp list --resource-group $rg --query "[].name" -o tsv 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $names) { return "" }
    return (($names -split "`n") | Where-Object { $_ -like "$prefix*" } | Select-Object -First 1).Trim()
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Granting API identity SQL access" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# ── Resolve configuration: explicit parameters take precedence, then azd env ──
$resourceGroup = if ($ResourceGroupName) { $ResourceGroupName } else { Get-AzdValue "RESOURCE_GROUP_NAME" }
$server        = if ($SqlServerName) { $SqlServerName } else { Get-AzdValue "AZURE_SQL_SERVER" }
$database      = if ($SqlDatabaseName) { $SqlDatabaseName } else { Get-AzdValue "AZURE_SQL_DATABASE" }
$apiName       = if ($ApiAppName) { $ApiAppName } else { Get-AzdValue "API_APP_NAME" }
$principalId   = if ($PrincipalId) { $PrincipalId } else { Get-AzdValue "AZURE_API_PRINCIPAL_ID" }

$envName    = Get-AzdValue "AZURE_ENV_NAME"
$backendUri = Get-AzdValue "SERVICE_BACKEND_URI"

# Fallbacks for azd environments provisioned before the API_APP_NAME / AZURE_API_PRINCIPAL_ID
# outputs were added: derive the app name from the backend URI.
if (-not $apiName -and $backendUri -match 'https://([^.]+)\.azurewebsites') {
    $apiName = $Matches[1]
}

# ── Auto-discovery from the resource group (used when azd is unavailable/didn't resolve a value) ──
if (-not $server)   { $server   = Get-DiscoveredSqlServerName $resourceGroup }
if (-not $apiName)  { $apiName  = Get-DiscoveredWebAppName $resourceGroup "api-" }
if (-not $database) { $database = Get-DiscoveredSqlDatabaseName $resourceGroup ($server -replace '\.database\.windows\.net$', '') }

if (-not $principalId -and $apiName) {
    $rgForLookup = if ($resourceGroup) { $resourceGroup } elseif ($envName) { "rg-$envName" } else { "" }
    if ($rgForLookup) {
        $principalId = (az webapp identity show --name $apiName --resource-group $rgForLookup --query principalId -o tsv 2>$null)
    }
}

if (-not $server -or -not $database -or -not $apiName -or -not $principalId) {
    Write-Host "Skipping SQL role assignment — missing SQL server / database / API app name / principal ID." -ForegroundColor Yellow
    if (-not $azdAvailable -or -not $resourceGroup) {
        Write-Host "       For non-azd/AVM deployments, pass -ResourceGroupName (and optionally -SqlServerName, -SqlDatabaseName, -ApiAppName, -PrincipalId)." -ForegroundColor Yellow
    }
    exit 0
}

$accountType = (az account show --query user.type -o tsv 2>$null)
$isServicePrincipal = ($accountType -eq 'servicePrincipal')

$roles = @(
    @{ principalId = $principalId; displayName = $apiName; role = "db_datareader";  isServicePrincipal = $isServicePrincipal },
    @{ principalId = $principalId; displayName = $apiName; role = "db_datawriter";  isServicePrincipal = $isServicePrincipal },
    @{ principalId = $principalId; displayName = $apiName; role = "db_ddladmin";    isServicePrincipal = $isServicePrincipal }
)

# Write to a temp file to avoid CLI JSON quoting issues across shells
$tmp = [System.IO.Path]::GetTempFileName()
ConvertTo-Json -InputObject $roles -Depth 5 | Set-Content -Path $tmp -Encoding utf8

Write-Host "API identity : $apiName ($principalId), account type: $accountType" -ForegroundColor DarkGray
Write-Host "SQL target   : $server / $database" -ForegroundColor DarkGray

$script = Join-Path $PSScriptRoot "add_user_scripts/assign_sql_roles.py"
python $script --server $server --database $database --roles-file $tmp
$exit = $LASTEXITCODE

Remove-Item -Force $tmp -ErrorAction SilentlyContinue

if ($exit -ne 0) {
    Write-Host "WARNING: SQL role assignment failed — the API may not be able to read SQL." -ForegroundColor Yellow
    exit $exit
}

Write-Host "SQL roles assigned." -ForegroundColor Green

