# ==============================================================================
# Destroy Script (Windows PowerShell)
# Couchbase Capella + Kafka + OpenTelemetry Demo Project
# ==============================================================================

$ErrorActionPreference = "Stop"

function Write-Info ($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Success ($msg) { Write-Host "[SUCCESS] $msg" -ForegroundColor Green }
function Write-ErrorAlert ($msg) { Write-Host "[ERROR] $msg" -ForegroundColor Red; Exit 1 }

$envFile = Join-Path $PSScriptRoot ".env"

if (-not (Test-Path $envFile)) {
    Write-ErrorAlert "No .env file found. Cannot determine configuration for destroy."
}

# Load environment variables
Write-Info "Loading environment variables..."
$envVars = @{}
Get-Content $envFile | Where-Object { $_ -match '=' -and -not $_.StartsWith("#") } | ForEach-Object {
    $parts = $_ -split '=', 2
    $key = $parts[0].Trim()
    $val = $parts[1].Trim().Trim('"').Trim("'")
    [System.Environment]::SetEnvironmentVariable($key, $val, [System.EnvironmentVariableTarget]::Process)
    $envVars[$key] = $val
}

Write-Info "Verifying Azure login..."
$azAccount = az account show | ConvertFrom-Json
if (-not $azAccount) {
    Write-ErrorAlert "Not logged into Azure CLI. Please run 'az login' first."
}

Write-Info "Running Terraform Destroy..."
Push-Location (Join-Path $PSScriptRoot "infra")

$env:TF_VAR_subscription_id    = $envVars["AZURE_SUBSCRIPTION_ID"]
$env:TF_VAR_location           = $envVars["AZURE_LOCATION"]
$env:TF_VAR_prefix             = $envVars["RESOURCE_PREFIX"]
$env:TF_VAR_vm_size            = $envVars["AZURE_VM_SIZE"]
$env:TF_VAR_admin_username     = $envVars["VM_ADMIN_USERNAME"]
$env:TF_VAR_capella_auth_token = $envVars["CAPELLA_AUTH_TOKEN"]

terraform destroy -auto-approve
Write-Success "Demo infrastructure has been successfully destroyed!"
Pop-Location

# Clean up SSH key files left by deploy.ps1
$prefix = if ($envVars["RESOURCE_PREFIX"]) { $envVars["RESOURCE_PREFIX"] } else { "cb-otel-demo" }
Get-ChildItem -Path $PSScriptRoot -Filter "$prefix-*.pem" | ForEach-Object {
    Remove-Item $_.FullName -Force
    Write-Success "Removed SSH key: $($_.Name)"
}
