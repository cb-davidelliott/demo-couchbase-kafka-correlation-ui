param(
    [string]$Endpoint = $env:COUCHBASE_DATA_API_ENDPOINT,
    [string]$Username = $env:COUCHBASE_DATA_API_USERNAME,
    [System.Management.Automation.PSCredential]$Credential,
    [string]$Bucket = $(if ($env:COUCHBASE_BUCKET) { $env:COUCHBASE_BUCKET } else { "demo" }),
    [string]$Scope = $(if ($env:COUCHBASE_SCOPE) { $env:COUCHBASE_SCOPE } else { "app360" }),
    [switch]$RunSamples
)

$ErrorActionPreference = "Stop"

if (-not $Credential -and $Username -and $env:COUCHBASE_DATA_API_PASSWORD) {
    $securePassword = ConvertTo-SecureString $env:COUCHBASE_DATA_API_PASSWORD -AsPlainText -Force
    $Credential = [System.Management.Automation.PSCredential]::new($Username, $securePassword)
}

if (-not $Endpoint -or -not $Credential) {
    Write-Error "Set COUCHBASE_DATA_API_ENDPOINT plus COUCHBASE_DATA_API_USERNAME/COUCHBASE_DATA_API_PASSWORD, or pass -Endpoint and -Credential."
}

$Endpoint = $Endpoint.TrimEnd("/")
$QueryUrl = "$Endpoint/_p/query/query/service"
$usernameForAuth = $Credential.UserName
$passwordPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
try {
    $passwordForAuth = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPtr)
    $AuthPair = "${usernameForAuth}:${passwordForAuth}"
    $Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($AuthPair))
} finally {
    if ($passwordPtr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPtr)
    }
}
$Headers = @{
    Authorization  = "Basic $Auth"
    Accept         = "application/json"
    "Content-Type" = "application/json"
}

function Invoke-DataApiQuery {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Statement
    )

    $body = @{ statement = $Statement } | ConvertTo-Json -Compress
    try {
        return Invoke-RestMethod -Method Post -Uri $QueryUrl -Headers $Headers -Body $body -TimeoutSec 120
    } catch {
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
            $message = $_.ErrorDetails.Message
            if (-not $message) {
                $reader = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
                $message = $reader.ReadToEnd()
            }
            throw "HTTP $status $message"
        }
        throw
    }
}

function Escape-SqlString {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return "" }
    return $Value.Replace("'", "''")
}

function Keyspace {
    param([Parameter(Mandatory = $true)][string]$Collection)
    return "``$Bucket``.``$Scope``.``$Collection``"
}

function First-Raw {
    param([Parameter(Mandatory = $true)][string]$Statement)
    try {
        $response = Invoke-DataApiQuery -Statement $Statement
        if ($response.status -ne "success" -or -not $response.results -or $response.results.Count -eq 0) {
            return $null
        }
        return $response.results[0]
    } catch {
        Write-Warning "Could not fetch sample value: $($_.Exception.Message)"
        return $null
    }
}

function Add-Test {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Tests,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Statement,
        [string]$Mode = "explain"
    )

    [void]$Tests.Add([ordered]@{
        Name      = $Name
        Mode      = $Mode
        Statement = $Statement
    })
}

function Run-Test {
    param([Parameter(Mandatory = $true)]$Test)

    $statement = if ($Test.Mode -eq "explain") {
        "EXPLAIN $($Test.Statement)"
    } else {
        $Test.Statement
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-DataApiQuery -Statement $statement
        $sw.Stop()
        if ($response.status -eq "success") {
            $resultCount = if ($response.metrics.resultCount -ne $null) { $response.metrics.resultCount } else { 0 }
            [pscustomobject]@{
                Status    = "PASS"
                Mode      = $Test.Mode
                Name      = $Test.Name
                ElapsedMs = $sw.ElapsedMilliseconds
                Results   = $resultCount
                Error     = ""
            }
        } else {
            [pscustomobject]@{
                Status    = "FAIL"
                Mode      = $Test.Mode
                Name      = $Test.Name
                ElapsedMs = $sw.ElapsedMilliseconds
                Results   = 0
                Error     = ($response.errors | ConvertTo-Json -Compress -Depth 6)
            }
        }
    } catch {
        $sw.Stop()
        [pscustomobject]@{
            Status    = "FAIL"
            Mode      = $Test.Mode
            Name      = $Test.Name
            ElapsedMs = $sw.ElapsedMilliseconds
            Results   = 0
            Error     = $_.Exception.Message
        }
    }
}

Write-Host "[INFO] Verifying Data API caller..."
$caller = Invoke-RestMethod -Method Get -Uri "$Endpoint/v1/callerIdentity" -Headers $Headers -TimeoutSec 30
Write-Host "[INFO] Data API caller: $($caller.user)"

$incidents = Keyspace "incidents"
$orders = Keyspace "orders"
$payments = Keyspace "payments"
$tickets = Keyspace "support_tickets"
$shipments = Keyspace "shipments"
$deployments = Keyspace "deployments"
$accounts = Keyspace "accounts"
$customers = Keyspace "customers"
$services = Keyspace "services"
$traces = Keyspace "traces"
$logs = Keyspace "logs"
$metrics = Keyspace "metrics"

Write-Host "[INFO] Discovering sample IDs..."
$incidentId = First-Raw "SELECT RAW i.incidentId FROM $incidents i WHERE i.startedAt IS NOT MISSING ORDER BY i.startedAt DESC LIMIT 1;"
if (-not $incidentId) {
    $incidentId = First-Raw "SELECT RAW i.incidentId FROM $incidents i WHERE i.incidentId IS NOT MISSING LIMIT 1;"
}
$orderId = First-Raw "SELECT RAW o.orderId FROM $orders o WHERE o.orderId IS NOT MISSING LIMIT 1;"
$traceId = First-Raw "SELECT RAW o.traceId FROM $orders o WHERE o.traceId IS NOT MISSING LIMIT 1;"
$customerId = First-Raw "SELECT RAW o.customerId FROM $orders o WHERE o.customerId IS NOT MISSING LIMIT 1;"
$accountId = First-Raw "SELECT RAW o.accountId FROM $orders o WHERE o.accountId IS NOT MISSING LIMIT 1;"

Write-Host "[INFO] Samples: incidentId=$incidentId orderId=$orderId traceId=$traceId customerId=$customerId accountId=$accountId"

$incidentSql = Escape-SqlString $incidentId
$orderSql = Escape-SqlString $orderId
$traceSql = Escape-SqlString $traceId
$customerSql = Escape-SqlString $customerId
$accountSql = Escape-SqlString $accountId

$tests = [System.Collections.Generic.List[object]]::new()

Add-Test $tests "incident-list" @"
SELECT i.incidentId, i.scenario, i.title, i.severity, i.status, i.startedAt
FROM $incidents i
WHERE i.startedAt IS NOT MISSING
ORDER BY i.startedAt DESC
LIMIT 12;
"@

if ($incidentId) {
    Add-Test $tests "incident-summary-incident" "SELECT i.* FROM $incidents i WHERE i.incidentId = '$incidentSql' LIMIT 1;"
    Add-Test $tests "incident-summary-payments" "SELECT p.paymentId, p.orderId, p.accountId, p.authorizationStatus, p.latencyMs, p.createdTime FROM $payments p WHERE p.incidentId = '$incidentSql' ORDER BY p.createdTime DESC LIMIT 25;"
    Add-Test $tests "incident-summary-tickets" "SELECT t.ticketId, t.accountId, t.customerId, t.issueType, t.severity, t.createdTime FROM $tickets t WHERE t.incidentId = '$incidentSql' ORDER BY t.createdTime DESC LIMIT 25;"
    Add-Test $tests "incident-summary-orders" "SELECT o.orderId, o.accountId, o.accountName, o.totalAmount FROM $orders o WHERE o.incidentId = '$incidentSql' ORDER BY o.orderTime DESC LIMIT 25;"
    Add-Test $tests "incident-summary-deployments" "SELECT d.deploymentId, d.serviceName, d.version, d.status, d.timestamp FROM $deployments d WHERE d.incidentId = '$incidentSql' ORDER BY d.timestamp DESC LIMIT 8;"
    Add-Test $tests "root-cause-order-signals" @"
WITH recent_orders AS (
  SELECT o.serviceName, o.orderId, o.traceId, o.status, o.totalAmount
  FROM $orders o
  WHERE o.incidentId = '$incidentSql'
  ORDER BY o.orderTime DESC
  LIMIT 1000
)
SELECT IFMISSINGORNULL(o.serviceName, "unknown") AS serviceName,
       COUNT(DISTINCT o.orderId) AS impactedOrders,
       COUNT(DISTINCT o.traceId) AS traceCount,
       ROUND(SUM(o.totalAmount), 2) AS revenueAtRisk
FROM recent_orders o
GROUP BY IFMISSINGORNULL(o.serviceName, "unknown");
"@
    Add-Test $tests "root-cause-payment-signals" @"
WITH recent_payments AS (
  SELECT p.serviceName, p.paymentId, p.orderId, p.traceId, p.authorizationStatus, p.latencyMs, p.createdTime
  FROM $payments p
  WHERE p.incidentId = '$incidentSql'
  ORDER BY p.createdTime DESC
  LIMIT 1000
)
SELECT IFMISSINGORNULL(p.serviceName, "unknown") AS serviceName,
       COUNT(1) AS paymentAttempts,
       SUM(CASE WHEN p.authorizationStatus = "DECLINED" THEN 1 ELSE 0 END) AS failedPayments,
       SUM(CASE WHEN p.latencyMs >= 800 THEN 1 ELSE 0 END) AS slowPayments,
       ROUND(AVG(p.latencyMs), 2) AS avgLatencyMs
FROM recent_payments p
GROUP BY IFMISSINGORNULL(p.serviceName, "unknown");
"@
    Add-Test $tests "timeline-orders-by-incident" "SELECT o.orderId, o.customerId, o.accountId, o.incidentId, o.traceId, o.status, o.orderTime FROM $orders o WHERE o.incidentId = '$incidentSql' ORDER BY o.orderTime DESC LIMIT 50;"
    Add-Test $tests "timeline-payments-by-incident" "SELECT p.paymentId, p.orderId, p.customerId, p.accountId, p.incidentId, p.traceId, p.createdTime FROM $payments p WHERE p.incidentId = '$incidentSql' ORDER BY p.createdTime DESC LIMIT 50;"
    Add-Test $tests "timeline-shipments-by-incident" "SELECT s.shipmentId, s.orderId, s.customerId, s.accountId, s.incidentId, s.traceId, s.createdTime FROM $shipments s WHERE s.incidentId = '$incidentSql' ORDER BY s.createdTime DESC LIMIT 50;"
    Add-Test $tests "timeline-tickets-by-incident" "SELECT t.ticketId, t.customerId, t.accountId, t.orderId, t.incidentId, t.traceId, t.createdTime FROM $tickets t WHERE t.incidentId = '$incidentSql' ORDER BY t.createdTime DESC LIMIT 50;"
}

if ($accountId) {
    Add-Test $tests "account-impact-profile" "SELECT a.* FROM $accounts a WHERE a.accountId = '$accountSql' LIMIT 1;"
    Add-Test $tests "account-impact-orders" "SELECT o.orderId, o.customerId, o.incidentId, o.traceId, o.status, o.totalAmount, o.orderTime FROM $orders o WHERE o.accountId = '$accountSql' ORDER BY o.orderTime DESC LIMIT 10;"
    Add-Test $tests "account-impact-payments" "SELECT p.paymentId, p.orderId, p.authorizationStatus, p.latencyMs, p.createdTime FROM $payments p WHERE p.accountId = '$accountSql' ORDER BY p.createdTime DESC LIMIT 25;"
}

if ($customerId) {
    Add-Test $tests "customer-impact-profile" "SELECT c.* FROM $customers c WHERE c.customerId = '$customerSql' LIMIT 1;"
    Add-Test $tests "customer-impact-orders" "SELECT o.orderId, o.accountId, o.accountName, o.incidentId, o.traceId, o.status, o.totalAmount, o.orderTime FROM $orders o WHERE o.customerId = '$customerSql' ORDER BY o.orderTime DESC LIMIT 10;"
    Add-Test $tests "customer-impact-tickets" "SELECT t.ticketId, t.issueType, t.severity, t.sentiment, t.status, t.createdTime FROM $tickets t WHERE t.customerId = '$customerSql' ORDER BY t.createdTime DESC LIMIT 25;"
}

if ($traceId) {
    Add-Test $tests "search-by-trace" "SELECT o.orderId, o.customerId, o.traceId, o.totalAmount, o.orderTime, 'order' AS docType FROM $orders o WHERE o.traceId = '$traceSql' LIMIT 20;"
    Add-Test $tests "correlation-order-customer" "SELECT o.orderId, o.customerId, o.sessionId, o.totalAmount, o.orderTime, o.traceId, c.name AS customerName FROM $orders o LEFT JOIN $customers c ON o.customerId = c.customerId WHERE o.traceId = '$traceSql' LIMIT 20;"
    Add-Test $tests "correlation-tickets" "SELECT t.ticketId, t.issueType, t.status, t.createdTime, t.traceId FROM $tickets t WHERE t.traceId = '$traceSql' LIMIT 20;"
    Add-Test $tests "correlation-spans" @"
SELECT s.name AS spanName, s.spanId, s.parentSpanId,
       DIV(TONUMBER(s.startTimeUnixNano), 1000000) AS startTimeMs,
       DIV(TONUMBER(s.endTimeUnixNano) - TONUMBER(s.startTimeUnixNano), 1000000) AS durationMs
FROM $traces t
UNNEST t.resourceSpans AS rs
UNNEST rs.scopeSpans AS ss
UNNEST ss.spans AS s
WHERE s.traceId = '$traceSql'
ORDER BY s.startTimeUnixNano ASC
LIMIT 20;
"@
    Add-Test $tests "correlation-logs" @"
SELECT lr.severityText AS severity,
       lr.body.stringValue AS logMessage,
       DIV(TONUMBER(lr.timeUnixNano), 1000000) AS timestampMs
FROM $logs l
UNNEST l.resourceLogs AS rl
UNNEST rl.scopeLogs AS sl
UNNEST sl.logRecords AS lr
WHERE ANY x WITHIN l.resourceLogs SATISFIES x.traceId = '$traceSql' END
  AND lr.traceId = '$traceSql'
ORDER BY lr.timeUnixNano ASC
LIMIT 20;
"@
}

Add-Test $tests "metrics-coverage" @"
SELECT mt.resourceMetrics
FROM $metrics mt
WHERE ANY m WITHIN mt.resourceMetrics SATISFIES m.name IS NOT MISSING END
LIMIT 20;
"@

if ($RunSamples) {
    Add-Test $tests "sample-incident-list-execute" "SELECT i.incidentId, i.status, i.startedAt FROM $incidents i WHERE i.startedAt IS NOT MISSING ORDER BY i.startedAt DESC LIMIT 3;" "execute"
    if ($incidentId) {
        Add-Test $tests "sample-operator-blast-radius-execute" "SELECT o.orderId, o.customerId, o.accountId, o.status, ROUND(o.totalAmount, 2) AS totalAmount, o.orderTime FROM $orders o WHERE o.incidentId = '$incidentSql' ORDER BY o.orderTime DESC LIMIT 3;" "execute"
    }
    Add-Test $tests "sample-metrics-coverage-execute" "SELECT mt.resourceMetrics FROM $metrics mt WHERE ANY m WITHIN mt.resourceMetrics SATISFIES m.name IS NOT MISSING END LIMIT 3;" "execute"
}

Write-Host "[INFO] Running $($tests.Count) Data API query validations..."
$results = foreach ($test in $tests) {
    $result = Run-Test $test
    $prefix = if ($result.Status -eq "PASS") { "[PASS]" } else { "[FAIL]" }
    Write-Host "$prefix $($result.Mode) $($result.Name) ($($result.ElapsedMs)ms)"
    if ($result.Status -ne "PASS") {
        Write-Host "       $($result.Error)"
    }
    $result
}

Write-Host ""
Write-Host "Summary"
$results | Group-Object Status | ForEach-Object {
    Write-Host "  $($_.Name): $($_.Count)"
}

$failed = @($results | Where-Object { $_.Status -ne "PASS" })
if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "Failures"
    $failed | Format-Table Status, Mode, Name, ElapsedMs, Error -AutoSize -Wrap
    exit 1
}
