#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Build and push the backend (km-api) and frontend (km-app) container images to
    the Azure Container Registry (ACR), then switch the App Services to run them.
.DESCRIPTION
    Uses `az acr build` so the images are built remotely inside ACR — no local
    Docker is required. Configuration is resolved, in order of precedence, from:
    1) explicit parameters, 2) the azd environment (ACR_NAME, ACR_LOGIN_SERVER,
    API_APP_NAME, FRONTEND_APP_NAME, image names/tags, RESOURCE_GROUP_NAME) when
    azd is available, 3) auto-discovery from the resource group (for non-azd /
    AVM-based deployments) - the ACR is discovered assuming a single registry in
    the group, and the API/frontend App Services are discovered by their 'api-'
    and 'app-' name prefixes, 4) built-in defaults for image names/tags. After
    pushing, each App Service is pointed at its ACR image and set to pull via
    managed identity, then restarted.
.PARAMETER ResourceGroupName
    Name of the resource group the solution was deployed into. Required when not
    using azd (also used for auto-discovery of the ACR/App Service names).
.PARAMETER AcrName
    Name of the Azure Container Registry. Auto-discovered from the resource group
    when omitted (assumes a single ACR in the group).
.PARAMETER AcrLoginServer
    Login server of the ACR (defaults to "<AcrName>.azurecr.io" if omitted).
.PARAMETER ApiAppName
    Name of the API App Service. Auto-discovered from the resource group when
    omitted (matches an app whose name starts with "api-").
.PARAMETER FrontendAppName
    Name of the frontend App Service. Auto-discovered from the resource group
    when omitted (matches an app whose name starts with "app-").
.PARAMETER BackendImageName
    Backend image name (defaults to "km-api").
.PARAMETER BackendImageTag
    Backend image tag (defaults to "latest").
.PARAMETER FrontendImageName
    Frontend image name (defaults to "km-app").
.PARAMETER FrontendImageTag
    Frontend image tag (defaults to "latest").
.EXAMPLE
    # azd-based deployment (values resolved automatically from azd environment)
    ./infra/scripts/build/build_and_push_images.ps1
.EXAMPLE
    # AVM / non-azd deployment (ACR/App Services auto-discovered from the resource group)
    ./infra/scripts/build/build_and_push_images.ps1 -ResourceGroupName "my-rg"
.EXAMPLE
    # AVM / non-azd deployment (explicit parameters, e.g. multiple ACRs/apps in the group)
    ./infra/scripts/build/build_and_push_images.ps1 `
        -ResourceGroupName "my-rg" `
        -AcrName "kmcontainerreg" `
        -ApiAppName "app-abc123-api" `
        -FrontendAppName "app-abc123"
#>

param(
    [string]$ResourceGroupName,
    [string]$AcrName,
    [string]$AcrLoginServer,
    [string]$ApiAppName,
    [string]$FrontendAppName,
    [string]$BackendImageName,
    [string]$BackendImageTag,
    [string]$FrontendImageName,
    [string]$FrontendImageTag
)

$ErrorActionPreference = "Stop"

# Repo root is three levels up from this script (infra/scripts/build -> repo root)
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "../../..")).Path

$azdAvailable = [bool](Get-Command azd -ErrorAction SilentlyContinue)

function Get-AzdValue([string]$key) {
    if (-not $azdAvailable) { return "" }
    $val = (azd env get-value $key 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $val -or $val -match 'ERROR|not found') { return "" }
    return $val.Trim()
}

# ── Auto-discovery helpers (non-azd / AVM-based deployments): resolve names from the
#    resource group when not supplied explicitly and not available via azd. ──
function Get-DiscoveredAcrName([string]$rg) {
    if (-not $rg) { return "" }
    $names = (az acr list --resource-group $rg --query "[].name" -o tsv 2>$null)
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
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host "  Build & Push Container Images" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host ""

# ── Ensure Azure CLI is authenticated ──
az account show *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Not logged in to Azure CLI. Launching 'az login'..." -ForegroundColor Yellow
    az login | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Azure CLI login failed." -ForegroundColor Red
        exit 1
    }
}

# ── Resolve configuration: explicit parameters take precedence, then azd env ──
$resourceGroup   = if ($ResourceGroupName) { $ResourceGroupName } else { Get-AzdValue "RESOURCE_GROUP_NAME" }
$acrName         = if ($AcrName) { $AcrName } else { Get-AzdValue "ACR_NAME" }
$acrLoginServer  = if ($AcrLoginServer) { $AcrLoginServer } else { Get-AzdValue "ACR_LOGIN_SERVER" }
$backendImage    = if ($BackendImageName) { $BackendImageName } else { Get-AzdValue "BACKEND_CONTAINER_IMAGE_NAME" }
$backendTag      = if ($BackendImageTag) { $BackendImageTag } else { Get-AzdValue "BACKEND_CONTAINER_IMAGE_TAG" }
$frontendImage   = if ($FrontendImageName) { $FrontendImageName } else { Get-AzdValue "FRONTEND_CONTAINER_IMAGE_NAME" }
$frontendTag     = if ($FrontendImageTag) { $FrontendImageTag } else { Get-AzdValue "FRONTEND_CONTAINER_IMAGE_TAG" }
$backendApp      = if ($ApiAppName) { $ApiAppName } else { Get-AzdValue "API_APP_NAME" }
$frontendApp     = if ($FrontendAppName) { $FrontendAppName } else { Get-AzdValue "FRONTEND_APP_NAME" }

# ── Auto-discovery from the resource group (used when azd is unavailable/didn't resolve a value) ──
if (-not $acrName)    { $acrName    = Get-DiscoveredAcrName $resourceGroup }
if (-not $backendApp) { $backendApp = Get-DiscoveredWebAppName $resourceGroup "api-" }
if (-not $frontendApp) { $frontendApp = Get-DiscoveredWebAppName $resourceGroup "app-" }

# ── Fallbacks / defaults ──
if (-not $acrLoginServer -and $acrName) { $acrLoginServer = "$acrName.azurecr.io" }
if (-not $backendImage)  { $backendImage  = "km-api" }
if (-not $backendTag)    { $backendTag    = "latest" }
if (-not $frontendImage) { $frontendImage = "km-app" }
if (-not $frontendTag)   { $frontendTag   = "latest" }

if (-not $acrName -or -not $backendApp -or -not $frontendApp) {
    Write-Host "ERROR: Could not resolve ACR / App Service names." -ForegroundColor Red
    if ($azdAvailable) {
        Write-Host "       Ensure 'azd provision' (or 'azd up') has completed for this environment," -ForegroundColor Yellow
        Write-Host "       or pass -AcrName, -ApiAppName and -FrontendAppName explicitly." -ForegroundColor Yellow
    } else {
        Write-Host "       Auto-discovery from -ResourceGroupName '$resourceGroup' did not find them (expects a single ACR and" -ForegroundColor Yellow
        Write-Host "       App Services named 'api-*'/'app-*'). Pass -AcrName, -ApiAppName and -FrontendAppName explicitly." -ForegroundColor Yellow
        Write-Host "       Example: ./infra/scripts/build/build_and_push_images.ps1 -ResourceGroupName '<rg>' -AcrName '<acr>' -ApiAppName '<api-app>' -FrontendAppName '<frontend-app>'" -ForegroundColor Yellow
    }
    exit 1
}

Write-Host "Resource Group:   $resourceGroup"
Write-Host "ACR Name:         $acrName"
Write-Host "ACR Login Server: $acrLoginServer"
Write-Host "Backend Image:    ${backendImage}:${backendTag}  -> App: $backendApp"
Write-Host "Frontend Image:   ${frontendImage}:${frontendTag}  -> App: $frontendApp"
Write-Host ""

# Build contexts and Dockerfiles
$backendContext    = Join-Path $repoRoot "src/api"
$backendDockerfile = Join-Path $repoRoot "src/api/ApiApp.Dockerfile"
$frontendContext    = Join-Path $repoRoot "src/app"
$frontendDockerfile = Join-Path $repoRoot "src/app/WebApp.Dockerfile"

function Build-Image([string]$image, [string]$tag, [string]$dockerfile, [string]$context) {
    if (-not (Test-Path $dockerfile)) {
        Write-Host "ERROR: Dockerfile not found: $dockerfile" -ForegroundColor Red
        exit 1
    }
    Write-Host "Building '${image}:${tag}' remotely in ACR '$acrName'..." -ForegroundColor Yellow
    az acr build --registry $acrName --image "${image}:${tag}" --file $dockerfile --platform linux $context
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Build of '${image}:${tag}' failed." -ForegroundColor Red
        exit 1
    }
    Write-Host "Pushed '${image}:${tag}'." -ForegroundColor Green
}

function Update-WebAppImage([string]$appName, [string]$image, [string]$tag) {
    $fullImage = "$acrLoginServer/${image}:${tag}"
    Write-Host ""
    Write-Host "Pointing App Service '$appName' at '$fullImage'..." -ForegroundColor Yellow
    az webapp config container set `
        --name $appName `
        --resource-group $resourceGroup `
        --container-image-name $fullImage `
        --container-registry-url "https://$acrLoginServer" `
        --only-show-errors `
        --output none
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Failed to set container image on '$appName'." -ForegroundColor Red
        exit 1
    }
    # Pull via managed identity (no admin credentials)
    az resource update `
        --resource-group $resourceGroup `
        --namespace Microsoft.Web `
        --resource-type sites `
        --name $appName `
        --set properties.siteConfig.acrUseManagedIdentityCreds=true `
        --output none 2>$null
    Write-Host "Restarting App Service '$appName'..." -ForegroundColor Yellow
    az webapp restart --name $appName --resource-group $resourceGroup --output none
    Write-Host "App Service '$appName' updated." -ForegroundColor Green
}

# ── Build & push both images ──
Build-Image $backendImage  $backendTag  $backendDockerfile  $backendContext
Build-Image $frontendImage $frontendTag $frontendDockerfile $frontendContext

# ── Switch App Services to the freshly pushed images ──
Update-WebAppImage $backendApp  $backendImage  $backendTag
Update-WebAppImage $frontendApp $frontendImage $frontendTag

Write-Host ""
Write-Host "===============================================" -ForegroundColor Green
Write-Host "  Images built & pushed; App Services updated." -ForegroundColor Green
Write-Host "===============================================" -ForegroundColor Green
Write-Host ""
