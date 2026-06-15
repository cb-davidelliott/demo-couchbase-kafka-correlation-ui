# ==============================================================================
# Validation Script (Windows PowerShell)
# Verifies that all components of the demo environment are active and healthy.
# ==============================================================================

$ErrorActionPreference = "Stop"

function Write-Info ($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Success ($msg) { Write-Host "[SUCCESS] $msg" -ForegroundColor Green }
function Write-Failure ($msg) { Write-Host "[FAIL] $msg" -ForegroundColor Red }

# Derive SSH key path from .env so connector checks can tunnel through SSH
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$envFile = Join-Path $repoRoot ".env"
$envVars = @{}
if (Test-Path $envFile) {
    Get-Content $envFile | Where-Object { $_ -match '^\s*[^#]' -and $_ -match '=' } | ForEach-Object {
        $parts = $_ -split '=', 2
        if ($parts.Length -eq 2) {
            $envVars[$parts[0].Trim()] = $parts[1].Trim().Trim('"').Trim("'")
        }
    }
}
$resourcePrefix   = if ($envVars['RESOURCE_PREFIX'])   { $envVars['RESOURCE_PREFIX'] }   else { "cb-otel-demo" }
$vmAdminUsername  = if ($envVars['VM_ADMIN_USERNAME'])  { $envVars['VM_ADMIN_USERNAME'] }  else { "azureuser" }
# $keyPath is derived after $vmIp is known — deploy.ps1 names the key {prefix}-{IP-with-dashes}.pem
$keyPath = $null

function Invoke-SshVm($Command) {
    if (-not (Test-Path $keyPath)) {
        throw "SSH key not found at $keyPath - cannot reach Kafka Connect REST API."
    }
    # LogLevel=ERROR suppresses informational messages (e.g. "Permanently added to known hosts")
    # that would otherwise mix into stdout and break JSON parsing.
    $result = ssh -i $keyPath -o StrictHostKeyChecking=no -o BatchMode=yes `
        -o ConnectTimeout=10 -o LogLevel=ERROR "${vmAdminUsername}@${vmIp}" $Command 2>$null
    return $result
}

$failures = 0
function Test-Step($Name, [scriptblock]$Check) {
    Write-Info $Name
    try {
        & $Check
        Write-Success $Name
    } catch {
        $script:failures++
        Write-Failure "$Name - $($_.Exception.Message)"
    }
}

# 1. Retrieve VM Public IP from Terraform
Write-Info "Retrieving VM Public IP from Terraform output..."
$infraDir = Join-Path $PSScriptRoot "..\infra"
if (Test-Path $infraDir) {
    Push-Location $infraDir
    $vmIp = terraform output -raw vm_public_ip
    Pop-Location
} else {
    Write-Failure "infra directory not found. Please run this script from the repository root."
    Exit 1
}

if (-not $vmIp) {
    Write-Failure "Could not fetch VM IP. Has the environment been deployed?"
    Exit 1
}
Write-Success "VM Public IP detected: $vmIp"

# Derive key path using the same naming convention as deploy.ps1: {prefix}-{IP-with-dashes}.pem
$safeVmIp = $vmIp -replace '[^0-9A-Za-z-]', '-'
$keyPath = Join-Path $repoRoot "$resourcePrefix-$safeVmIp.pem"

# 2. Verify externally exposed ports (8083 is loopback-only on the VM; checked via SSH below)
foreach ($port in @(3000, 8080)) {
    Test-Step "Checking TCP port $port" {
        $tcp = Test-NetConnection -ComputerName $vmIp -Port $port -WarningAction SilentlyContinue
        if (-not $tcp.TcpTestSucceeded) {
            throw "Port $port is not reachable from this machine."
        }
    }
}

# 3. Verify Redpanda Console
Test-Step "Checking Redpanda Console HTTP" {
    $res = Invoke-WebRequest -Uri "http://${vmIp}:8080/" -Method Get -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
    if ($res.StatusCode -lt 200 -or $res.StatusCode -ge 400) {
        throw "Unexpected HTTP status: $($res.StatusCode)"
    }
}

# 4. Verify Kafka Connect via SSH (port 8083 is loopback-only on the VM)
Test-Step "Checking Kafka Connect API (via SSH)" {
    $raw = Invoke-SshVm "curl -s --max-time 10 http://localhost:8083/"
    $connect = $raw | ConvertFrom-Json
    if (-not $connect.version) {
        throw "Kafka Connect responded, but version was not present."
    }
}

# 5. Verify Couchbase Sink Connector is Registered
Test-Step "Checking connector registration" {
    $raw = Invoke-SshVm "curl -s --max-time 10 http://localhost:8083/connectors/couchbase-sink-connector"
    $connector = $raw | ConvertFrom-Json
    if ($connector.name -ne "couchbase-sink-connector") {
        $listRaw = Invoke-SshVm "curl -s --max-time 10 http://localhost:8083/connectors"
        $connectors = $listRaw | ConvertFrom-Json
        $connectorList = if ($connectors.Count -gt 0) { $connectors -join ", " } else { "(none)" }
        throw "couchbase-sink-connector was not found. Registered connectors: $connectorList"
    }
}

# 6. Verify Connector Target Collections
Test-Step "Checking connector target collections" {
    $raw = Invoke-SshVm "curl -s --max-time 10 http://localhost:8083/connectors/couchbase-sink-connector/config"
    $config = $raw | ConvertFrom-Json
    $topics = @("logs", "traces", "metrics", "customers", "orders", "support_tickets", "accounts", "services", "incidents", "payments", "shipments", "deployments")
    foreach ($topic in $topics) {
        $key = "couchbase.default.collection[$topic]"
        $property = $config.PSObject.Properties[$key]
        if (-not $property) {
            throw "Missing connector config key $key."
        }
        $value = [string]$property.Value
        if ($value -match '\$\{env:' -or $value -notmatch '^[^.]+\.[^.]+$') {
            throw "$key has unexpected value '$value'. Expected a literal scope.collection value such as app360.$topic."
        }
    }
}

# 7. Verify Tasks are RUNNING
Test-Step "Checking connector task status" {
    $raw = Invoke-SshVm "curl -s --max-time 10 http://localhost:8083/connectors/couchbase-sink-connector/status"
    $status = $raw | ConvertFrom-Json
    if ($status.connector.state -ne "RUNNING") {
        throw "Connector state is $($status.connector.state)."
    }
    $notRunningTasks = $status.tasks | Where-Object { $_.state -ne "RUNNING" }
    if ($notRunningTasks) {
        $states = ($notRunningTasks | ForEach-Object { "task $($_.id): $($_.state)" }) -join ", "
        throw "One or more connector tasks are not RUNNING: $states"
    }
}

# 8. Verify Demo UI is serving HTTP
Test-Step "Checking Demo UI HTTP" {
    $res = Invoke-WebRequest -Uri "http://${vmIp}:3000/" -Method Get -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
    if ($res.StatusCode -lt 200 -or $res.StatusCode -ge 400) {
        throw "Unexpected HTTP status: $($res.StatusCode)"
    }
}

# 9. Verify Incident Command Center API.
Test-Step "Checking Incident Command Center API" {
    $incidents = Invoke-RestMethod -Uri "http://${vmIp}:3000/api/incidents" -Method Get -TimeoutSec 30
    if ($incidents.Count -lt 1) {
        throw "No incidents returned from the Command Center API."
    }

    $impactIncidents = @($incidents | Where-Object { $_.affectedOrderCount -and [int]$_.affectedOrderCount -gt 0 })
    $preferredIncident = @($incidents | Where-Object { $_.incidentId -eq "INC-DEMO-001" }) | Select-Object -First 1
    if (-not $preferredIncident) {
        $preferredIncident = if ($impactIncidents.Count -gt 0) { $impactIncidents[0] } else { $incidents[0] }
    }

    $incidentId = $preferredIncident.incidentId
    if (-not $incidentId) {
        throw "Selected incident did not include incidentId."
    }

    $summary = Invoke-RestMethod -Uri "http://${vmIp}:3000/api/incidents/$incidentId/summary" -Method Get -TimeoutSec 30
    if (-not $summary.incident -or $summary.incident.incidentId -ne $incidentId) {
        throw "Incident summary did not return the expected incident."
    }

    $timeline = Invoke-RestMethod -Uri "http://${vmIp}:3000/api/timeline?incidentId=$incidentId" -Method Get -TimeoutSec 30
    if ($timeline.count -lt 1) {
        throw "Incident timeline did not return any events."
    }

    $rootCause = Invoke-RestMethod -Uri "http://${vmIp}:3000/api/incidents/$incidentId/root-cause" -Method Get -TimeoutSec 30
    if (-not $rootCause.incident -or $rootCause.incident.incidentId -ne $incidentId) {
        throw "Root cause endpoint did not return the expected incident."
    }
    if ($preferredIncident.affectedOrderCount -gt 0 -and (-not $rootCause.suspectedService -or -not $rootCause.suspectedService.serviceName)) {
        throw "Root cause endpoint did not identify a suspected service for an impacted incident."
    }

    $bestRecords = Invoke-RestMethod -Uri "http://${vmIp}:3000/api/demo/best-records" -Method Get -TimeoutSec 30
    if (-not $bestRecords.incident -or -not $bestRecords.incident.incidentId) {
        throw "Best demo records endpoint did not return an incident recommendation."
    }
    if ($bestRecords.ready -and (-not $bestRecords.recommendedPath -or $bestRecords.recommendedPath.Count -lt 3)) {
        throw "Best demo records endpoint did not return a usable recommended path."
    }

    if ($summary.topAccounts.Count -gt 0) {
        $accountId = $summary.topAccounts[0].accountId
        $accountImpact = Invoke-RestMethod -Uri "http://${vmIp}:3000/api/accounts/$accountId/impact" -Method Get -TimeoutSec 30
        if (-not $accountImpact.account -or $accountImpact.account.accountId -ne $accountId) {
            throw "Account 360 impact endpoint did not return the expected account."
        }
        if (-not $accountImpact.recommendedAction -or -not $accountImpact.recommendedAction.priority) {
            throw "Account 360 impact endpoint did not return a recommended action."
        }
    }

    if ($summary.recentOrders.Count -gt 0 -and $summary.recentOrders[0].customerId) {
        $customerId = $summary.recentOrders[0].customerId
        $customerImpact = Invoke-RestMethod -Uri "http://${vmIp}:3000/api/customers/$customerId/impact" -Method Get -TimeoutSec 30
        if (-not $customerImpact.customer -or $customerImpact.customer.customerId -ne $customerId) {
            throw "Customer 360 impact endpoint did not return the expected customer."
        }
        if (-not $customerImpact.recommendedAction -or -not $customerImpact.recommendedAction.priority) {
            throw "Customer 360 impact endpoint did not return a recommended action."
        }
    }
}

# 10. Verify data flow into Couchbase via Demo UI API.
Test-Step "Checking end-to-end data search" {
    $dataFlows = $false
    for ($i = 1; $i -le 6; $i++) {
        $bestRecords = Invoke-RestMethod -Uri "http://${vmIp}:3000/api/demo/best-records" -Method Get -TimeoutSec 30
        $searchId = $bestRecords.order.orderId
        $searchType = "orderId"
        if (-not $searchId -and $bestRecords.customer.customerId) {
            $searchId = $bestRecords.customer.customerId
            $searchType = "customerId"
        }
        if (-not $searchId) {
            Start-Sleep -Seconds 10
            continue
        }

        $encodedSearchId = [System.Uri]::EscapeDataString($searchId)
        $uiResponse = Invoke-RestMethod -Uri "http://${vmIp}:3000/api/search?query=$encodedSearchId&type=$searchType" -Method Get -TimeoutSec 30
        if ($uiResponse -is [array] -and $uiResponse.Count -gt 0) {
            $dataFlows = $true
            break
        }
        Start-Sleep -Seconds 10
    }
    if (-not $dataFlows) {
        throw "No customer/order data returned from the Demo UI search API yet."
    }
}

if ($failures -eq 0) {
    Write-Host "---------------------------------------------------------" -ForegroundColor Green
    Write-Host "  Demo Status: CORE SERVICES REACHABLE" -ForegroundColor Green
    Write-Host "  React UI: http://${vmIp}:3000" -ForegroundColor Green
    Write-Host "  Redpanda Console: http://${vmIp}:8080" -ForegroundColor Green
    Write-Host "  Kafka Connect (SSH): ssh -i `"$keyPath`" -L 8083:localhost:8083 ${vmAdminUsername}@${vmIp}" -ForegroundColor Green
    Write-Host "---------------------------------------------------------" -ForegroundColor Green
} else {
    Write-Failure "Validation completed with $failures failure(s). Troubleshoot from the first failed layer above."
    Exit 1
}
