# ==============================================================================
# Deploy Script (Windows PowerShell)
# Couchbase Capella + Kafka + OpenTelemetry Demo Project
# ==============================================================================

$ErrorActionPreference = "Stop"

# Helpers for styled output
function Write-Info ($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Success ($msg) { Write-Host "[SUCCESS] $msg" -ForegroundColor Green }
function Write-ErrorAlert ($msg) { Write-Host "[ERROR] $msg" -ForegroundColor Red; Exit 1 }

# 1. Verify Prerequisites
Write-Info "Verifying prerequisites..."
foreach ($cmd in @("git", "az", "terraform")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-ErrorAlert "Missing prerequisite command: $cmd. Please install it before proceeding."
    }
}
Write-Success "Prerequisites verified."

# 2. Check for .env file
$envFile = Join-Path $PSScriptRoot ".env"
$envExampleFile = Join-Path $PSScriptRoot ".env.example"

if (-not (Test-Path $envFile)) {
    Write-Info "Copying .env.example to .env..."
    Copy-Item $envExampleFile $envFile
    Write-Info "Please edit .env with your Azure and Couchbase Capella details, then re-run this script."
    Exit 0
}

# Load environment variables from .env
Write-Info "Loading environment variables..."
$envVars = @{}
Get-Content $envFile | Where-Object { $_ -match '=' -and -not $_.StartsWith("#") } | ForEach-Object {
    $parts = $_ -split '=', 2
    $key = $parts[0].Trim()
    $val = $parts[1].Trim().Trim('"').Trim("'")
    [System.Environment]::SetEnvironmentVariable($key, $val, [System.EnvironmentVariableTarget]::Process)
    $envVars[$key] = $val
}

# 3. Verify Azure Login
Write-Info "Verifying Azure login..."
$azAccount = az account show | ConvertFrom-Json
if (-not $azAccount) {
    Write-ErrorAlert "Not logged into Azure CLI. Please run 'az login' first."
}
Write-Success "Logged into Azure. Active subscription: $($azAccount.name)"

# Set target subscription if provided
$subId = $envVars["AZURE_SUBSCRIPTION_ID"]
if ($subId -and $subId -ne "your-azure-subscription-id") {
    Write-Info "Setting Azure subscription to: $subId"
    az account set --subscription $subId
}

# Verify repository is reachable by the VM's unauthenticated cloud-init clone
$repoUrl = $envVars["GITHUB_REPO_URL"]
if (-not $repoUrl) {
    Write-ErrorAlert "GITHUB_REPO_URL is not configured. Set it to a public or otherwise unauthenticated clone URL."
}

Write-Info "Verifying repository is publicly reachable: $repoUrl"
$oldGitTerminalPrompt = $env:GIT_TERMINAL_PROMPT
$env:GIT_TERMINAL_PROMPT = "0"
git -c credential.helper= -c credential.useHttpPath=true ls-remote $repoUrl HEAD *> $null
$gitLsRemoteExitCode = $LASTEXITCODE
$env:GIT_TERMINAL_PROMPT = $oldGitTerminalPrompt
if ($gitLsRemoteExitCode -ne 0) {
    Write-ErrorAlert "Repository is not reachable without credentials. Make the repo public or provide an unauthenticated clone URL before deploying."
}
Write-Success "Repository reachability verified."

# 4. Terraform Initialization & Apply
Write-Info "Initializing Terraform..."
Push-Location (Join-Path $PSScriptRoot "infra")
terraform init

Write-Info "Validating Terraform configuration..."
terraform validate

Write-Info "Applying Terraform configuration..."
foreach ($required in @("CAPELLA_AUTH_TOKEN", "CAPELLA_ORGANIZATION_ID", "CAPELLA_PROJECT_ID")) {
    if (-not $envVars[$required]) {
        Write-ErrorAlert "$required is required for deployment."
    }
}

$env:TF_VAR_subscription_id                             = $envVars["AZURE_SUBSCRIPTION_ID"]
$env:TF_VAR_location                                    = $envVars["AZURE_LOCATION"]
$env:TF_VAR_prefix                                      = $envVars["RESOURCE_PREFIX"]
$env:TF_VAR_vm_size                                     = $envVars["AZURE_VM_SIZE"]
$env:TF_VAR_admin_username                              = $envVars["VM_ADMIN_USERNAME"]
$env:TF_VAR_github_repo_url                             = $envVars["GITHUB_REPO_URL"]
$env:TF_VAR_capella_auth_token                          = $envVars["CAPELLA_AUTH_TOKEN"]
$env:TF_VAR_capella_organization_id                     = $envVars["CAPELLA_ORGANIZATION_ID"]
$env:TF_VAR_capella_project_id                          = $envVars["CAPELLA_PROJECT_ID"]
$env:TF_VAR_capella_cluster_region                      = if ($envVars["CAPELLA_CLUSTER_REGION"]) { $envVars["CAPELLA_CLUSTER_REGION"] } else { "eastus" }
$env:TF_VAR_couchbase_bucket                            = if ($envVars["COUCHBASE_BUCKET"]) { $envVars["COUCHBASE_BUCKET"] } else { "demo" }
$env:TF_VAR_couchbase_scope                             = if ($envVars["COUCHBASE_SCOPE"]) { $envVars["COUCHBASE_SCOPE"] } else { "app360" }
$env:TF_VAR_demo_preferred_incident_id                  = if ($envVars["DEMO_PREFERRED_INCIDENT_ID"]) { $envVars["DEMO_PREFERRED_INCIDENT_ID"] } else { "INC-DEMO-001" }
$env:TF_VAR_generator_profile                           = if ($envVars["GENERATOR_PROFILE"]) { $envVars["GENERATOR_PROFILE"] } else { "demo" }
$env:TF_VAR_generator_interval_seconds                  = if ($envVars["GENERATOR_INTERVAL_SECONDS"]) { $envVars["GENERATOR_INTERVAL_SECONDS"] } else { "5.0" }
$env:TF_VAR_generator_events_per_batch                  = if ($envVars["GENERATOR_EVENTS_PER_BATCH"]) { $envVars["GENERATOR_EVENTS_PER_BATCH"] } else { "1" }
$env:TF_VAR_generator_enable_otel_calls                 = if ($envVars["GENERATOR_ENABLE_OTEL_CALLS"]) { $envVars["GENERATOR_ENABLE_OTEL_CALLS"] } else { "true" }
$env:TF_VAR_generator_new_customer_probability          = if ($envVars["GENERATOR_NEW_CUSTOMER_PROBABILITY"]) { $envVars["GENERATOR_NEW_CUSTOMER_PROBABILITY"] } else { "0.2" }
$env:TF_VAR_generator_ticket_probability                = if ($envVars["GENERATOR_TICKET_PROBABILITY"]) { $envVars["GENERATOR_TICKET_PROBABILITY"] } else { "0.25" }
$env:TF_VAR_generator_enable_metrics                    = if ($envVars["GENERATOR_ENABLE_METRICS"]) { $envVars["GENERATOR_ENABLE_METRICS"] } else { "true" }
$env:TF_VAR_generator_enable_incident_updates           = if ($envVars["GENERATOR_ENABLE_INCIDENT_UPDATES"]) { $envVars["GENERATOR_ENABLE_INCIDENT_UPDATES"] } else { "true" }
$env:TF_VAR_generator_unique_metric_docs                = if ($envVars["GENERATOR_UNIQUE_METRIC_DOCS"]) { $envVars["GENERATOR_UNIQUE_METRIC_DOCS"] } else { "false" }
$env:TF_VAR_generator_log_every_n_events                = if ($envVars["GENERATOR_LOG_EVERY_N_EVENTS"]) { $envVars["GENERATOR_LOG_EVERY_N_EVENTS"] } else { "1" }
$env:TF_VAR_generator_flush_every_n_events              = if ($envVars["GENERATOR_FLUSH_EVERY_N_EVENTS"]) { $envVars["GENERATOR_FLUSH_EVERY_N_EVENTS"] } else { "" }
$env:TF_VAR_generator_incident_update_every_n_events    = if ($envVars["GENERATOR_INCIDENT_UPDATE_EVERY_N_EVENTS"]) { $envVars["GENERATOR_INCIDENT_UPDATE_EVERY_N_EVENTS"] } else { "1" }
$env:TF_VAR_generator_producer_linger_ms                = if ($envVars["GENERATOR_PRODUCER_LINGER_MS"]) { $envVars["GENERATOR_PRODUCER_LINGER_MS"] } else { "5" }
$env:TF_VAR_generator_producer_batch_num_messages       = if ($envVars["GENERATOR_PRODUCER_BATCH_NUM_MESSAGES"]) { $envVars["GENERATOR_PRODUCER_BATCH_NUM_MESSAGES"] } else { "10000" }
$env:TF_VAR_generator_producer_queue_max_messages       = if ($envVars["GENERATOR_PRODUCER_QUEUE_MAX_MESSAGES"]) { $envVars["GENERATOR_PRODUCER_QUEUE_MAX_MESSAGES"] } else { "100000" }
$env:TF_VAR_generator_producer_compression              = if ($envVars["GENERATOR_PRODUCER_COMPRESSION"]) { $envVars["GENERATOR_PRODUCER_COMPRESSION"] } else { "lz4" }
$env:TF_VAR_generator_enterprise_account_count          = if ($envVars["GENERATOR_ENTERPRISE_ACCOUNT_COUNT"]) { $envVars["GENERATOR_ENTERPRISE_ACCOUNT_COUNT"] } else { "30" }
$env:TF_VAR_generator_scenario                          = if ($envVars["GENERATOR_SCENARIO"]) { $envVars["GENERATOR_SCENARIO"] } else { "payment_outage" }
$env:TF_VAR_generator_incident_id                       = if ($envVars["GENERATOR_INCIDENT_ID"]) { $envVars["GENERATOR_INCIDENT_ID"] } else { "" }
$env:TF_VAR_generator_random_seed                       = if ($envVars["GENERATOR_RANDOM_SEED"]) { $envVars["GENERATOR_RANDOM_SEED"] } else { "" }
$env:TF_VAR_generator_max_active_customers              = if ($envVars["GENERATOR_MAX_ACTIVE_CUSTOMERS"]) { $envVars["GENERATOR_MAX_ACTIVE_CUSTOMERS"] } else { "500" }


terraform apply -auto-approve

# 6. Output VM Status and Info
$vmIp = terraform output -raw vm_public_ip
$sshKey = (terraform output -raw ssh_private_key) -join [System.Environment]::NewLine
Pop-Location

$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

$safeVmIp = $vmIp -replace '[^0-9A-Za-z-]', '-'
$keyPath = Join-Path $PSScriptRoot "$($env:TF_VAR_prefix)-$safeVmIp.pem"
if (-not ($sshKey -match "-----BEGIN .*PRIVATE KEY-----" -and $sshKey -match "-----END .*PRIVATE KEY-----")) {
    Write-ErrorAlert "Terraform returned an SSH key, but it does not look like a PEM private key. Try: terraform output -raw ssh_private_key"
}

[System.IO.File]::WriteAllText($keyPath, $sshKey, [System.Text.Encoding]::ASCII)
icacls $keyPath /inheritance:r /grant:r "$($currentUser):(F)" | Out-Null

Write-Success "Terraform deployment complete!"
Write-Host "---------------------------------------------------------" -ForegroundColor Green
Write-Host " VM Public IP: $vmIp" -ForegroundColor Green
Write-Host " SSH Key: $keyPath" -ForegroundColor Green
Write-Host " SSH: ssh -i `"$keyPath`" $($env:TF_VAR_admin_username)@$vmIp" -ForegroundColor Green
Write-Host " Redpanda Console: http://$($vmIp):8080" -ForegroundColor Green
Write-Host " Demo UI: http://$($vmIp):3000" -ForegroundColor Green
Write-Host "---------------------------------------------------------" -ForegroundColor Green
Write-Host "NOTE: First deploy takes ~20 minutes — Terraform is creating the Capella cluster."
Write-Host "Wait until cloud-init finishes before opening the Demo UI."
Write-Host "Startup logs:" -ForegroundColor Cyan
Write-Host " ssh -i `"$keyPath`" $($env:TF_VAR_admin_username)@$vmIp `"sudo tail -120 /var/log/cloud-init-output.log`"" -ForegroundColor Cyan
Write-Host " ssh -i `"$keyPath`" $($env:TF_VAR_admin_username)@$vmIp `"sudo tail -120 /var/log/cb-demo-compose.log`"" -ForegroundColor Cyan
Write-Host " ssh -i `"$keyPath`" $($env:TF_VAR_admin_username)@$vmIp `"sudo tail -120 /var/log/cb-connector-setup.log`"" -ForegroundColor Cyan
