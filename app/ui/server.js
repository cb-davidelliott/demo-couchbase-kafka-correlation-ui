const express = require('express');
const couchbase = require('couchbase');
const path = require('path');
const dotenv = require('dotenv');

// Load environment variables locally if present
dotenv.config();

const app = express();
const PORT = process.env.PORT || 3000;

// Configuration from env
const connStr = process.env.COUCHBASE_CONN_STR;
const username = process.env.COUCHBASE_USERNAME;
const password = process.env.COUCHBASE_PASSWORD;
const bucketName = process.env.COUCHBASE_BUCKET || 'demo';
const scopeName = process.env.COUCHBASE_SCOPE || 'app360';
const indexTimeoutMs = Number(process.env.COUCHBASE_INDEX_TIMEOUT_MS || 600000);

let cluster = null;

async function ensureQueryIndexes() {
  if (process.env.ENSURE_COUCHBASE_INDEXES === 'false') {
    return;
  }

  const indexStatements = [
    `CREATE INDEX IF NOT EXISTS idx_orders_trace_time ON \`${bucketName}\`.\`${scopeName}\`.orders(traceId, orderTime DESC)`,
    `CREATE INDEX IF NOT EXISTS idx_orders_customer_time ON \`${bucketName}\`.\`${scopeName}\`.orders(customerId, orderTime DESC)`,
    `CREATE INDEX IF NOT EXISTS idx_orders_account_time ON \`${bucketName}\`.\`${scopeName}\`.orders(accountId, orderTime DESC)`,
    `CREATE INDEX IF NOT EXISTS idx_orders_incident_time ON \`${bucketName}\`.\`${scopeName}\`.orders(incidentId, orderTime DESC)`,
    `CREATE INDEX IF NOT EXISTS idx_orders_order_time ON \`${bucketName}\`.\`${scopeName}\`.orders(orderId, orderTime DESC)`,
    `CREATE INDEX IF NOT EXISTS idx_customers_customer ON \`${bucketName}\`.\`${scopeName}\`.customers(customerId)`,
    `CREATE INDEX IF NOT EXISTS idx_customers_account ON \`${bucketName}\`.\`${scopeName}\`.customers(accountId)`,
    `CREATE INDEX IF NOT EXISTS idx_tickets_trace_time ON \`${bucketName}\`.\`${scopeName}\`.support_tickets(traceId, createdTime DESC)`,
    `CREATE INDEX IF NOT EXISTS idx_tickets_status_trace ON \`${bucketName}\`.\`${scopeName}\`.support_tickets(status, traceId)`,
    `CREATE INDEX IF NOT EXISTS idx_tickets_account_time ON \`${bucketName}\`.\`${scopeName}\`.support_tickets(accountId, createdTime DESC)`,
    `CREATE INDEX IF NOT EXISTS idx_tickets_customer_time ON \`${bucketName}\`.\`${scopeName}\`.support_tickets(customerId, createdTime DESC)`,
    `CREATE INDEX IF NOT EXISTS idx_tickets_incident_time ON \`${bucketName}\`.\`${scopeName}\`.support_tickets(incidentId, createdTime DESC)`,
    `CREATE INDEX IF NOT EXISTS idx_accounts_account ON \`${bucketName}\`.\`${scopeName}\`.accounts(accountId)`,
    `CREATE INDEX IF NOT EXISTS idx_incidents_incident ON \`${bucketName}\`.\`${scopeName}\`.incidents(incidentId)`,
    `CREATE INDEX IF NOT EXISTS idx_incidents_status_started ON \`${bucketName}\`.\`${scopeName}\`.incidents(status, startedAt DESC)`,
    `CREATE INDEX IF NOT EXISTS idx_incidents_started ON \`${bucketName}\`.\`${scopeName}\`.incidents(startedAt DESC)`,
    `CREATE INDEX IF NOT EXISTS idx_payments_order ON \`${bucketName}\`.\`${scopeName}\`.payments(orderId)`,
    `CREATE INDEX IF NOT EXISTS idx_payments_incident_time ON \`${bucketName}\`.\`${scopeName}\`.payments(incidentId, createdTime DESC)`,
    `CREATE INDEX IF NOT EXISTS idx_payments_account_time ON \`${bucketName}\`.\`${scopeName}\`.payments(accountId, createdTime DESC)`,
    `CREATE INDEX IF NOT EXISTS idx_payments_customer_time ON \`${bucketName}\`.\`${scopeName}\`.payments(customerId, createdTime DESC)`,
    `CREATE INDEX IF NOT EXISTS idx_shipments_order ON \`${bucketName}\`.\`${scopeName}\`.shipments(orderId)`,
    `CREATE INDEX IF NOT EXISTS idx_shipments_incident_time ON \`${bucketName}\`.\`${scopeName}\`.shipments(incidentId, createdTime DESC)`,
    `CREATE INDEX IF NOT EXISTS idx_shipments_account_time ON \`${bucketName}\`.\`${scopeName}\`.shipments(accountId, createdTime DESC)`,
    `CREATE INDEX IF NOT EXISTS idx_shipments_customer_time ON \`${bucketName}\`.\`${scopeName}\`.shipments(customerId, createdTime DESC)`,
    `CREATE INDEX IF NOT EXISTS idx_deployments_incident_time ON \`${bucketName}\`.\`${scopeName}\`.deployments(incidentId, timestamp DESC)`,
    `CREATE INDEX IF NOT EXISTS idx_deployments_service_time ON \`${bucketName}\`.\`${scopeName}\`.deployments(serviceName, timestamp DESC)`,
    `CREATE INDEX IF NOT EXISTS idx_services_name ON \`${bucketName}\`.\`${scopeName}\`.services(serviceName)`,
    `CREATE INDEX IF NOT EXISTS idx_payments_incident_latency ON \`${bucketName}\`.\`${scopeName}\`.payments(incidentId, latencyMs DESC, createdTime DESC, authorizationStatus)`,
    `CREATE INDEX IF NOT EXISTS idx_orders_incident_amount ON \`${bucketName}\`.\`${scopeName}\`.orders(incidentId, totalAmount DESC, orderTime DESC)`,
    `CREATE INDEX IF NOT EXISTS idx_metrics_name ON \`${bucketName}\`.\`${scopeName}\`.\`metrics\`(DISTINCT ARRAY m.name FOR m WITHIN resourceMetrics WHEN m.name IS NOT MISSING END)`,
    `CREATE INDEX IF NOT EXISTS idx_traces_span_trace ON \`${bucketName}\`.\`${scopeName}\`.\`traces\`(DISTINCT ARRAY s.traceId FOR s WITHIN resourceSpans WHEN s.traceId IS NOT MISSING END)`,
    `CREATE INDEX IF NOT EXISTS idx_logs_record_trace ON \`${bucketName}\`.\`${scopeName}\`.\`logs\`(DISTINCT ARRAY lr.traceId FOR lr WITHIN resourceLogs WHEN lr.traceId IS NOT MISSING END)`
  ];

  for (const statement of indexStatements) {
    const indexName = statement.match(/CREATE INDEX IF NOT EXISTS\s+([^\s]+)/i)?.[1] || 'unknown_index';
    const timestamp = new Date().toISOString();
    try {
      console.log(`[INFO] ${timestamp} Verifying query index ${indexName} with timeout ${indexTimeoutMs}ms`);
      await cluster.query(statement, { timeout: indexTimeoutMs });
      console.log(`[INFO] ${new Date().toISOString()} Query index verified: ${indexName}`);
    } catch (err) {
      console.warn(`[WARN] ${new Date().toISOString()} Could not create query index ${indexName}: ${err.message}`);
      console.warn(`[WARN] ${new Date().toISOString()} Query index statement ${indexName}: ${statement}`);
    }
  }
}

// Initialize Couchbase Connection
async function connectDb() {
  if (!connStr || !username || !password) {
    console.warn('[WARN] Couchbase environment variables are missing. Running in mock/offline mode.');
    return;
  }
  
  try {
    console.log(`[INFO] Connecting to Couchbase Capella at: ${connStr}`);
    cluster = await couchbase.connect(connStr, {
      username: username,
      password: password,
      // Timeout settings for stable demo connectivity
      timeouts: {
        kvTimeout: 10000,
        queryTimeout: 30000
      }
    });
    console.log('[SUCCESS] Connected to Couchbase Capella!');
    await ensureQueryIndexes();
  } catch (err) {
    console.error('[ERROR] Failed to connect to Couchbase Capella:', err);
  }
}

connectDb();

// Middleware to serve static files
app.use(express.static(path.join(__dirname, 'public')));
app.use(express.json());

// Helper function to execute queries safely
async function runQuery(queryText, params = {}) {
  if (!cluster) {
    throw new Error('Database connection is not initialized.');
  }
  const result = await cluster.query(queryText, { parameters: params });
  return result.rows;
}

async function runQueryOrEmpty(label, queryText, params = {}) {
  try {
    return await runQuery(queryText, params);
  } catch (err) {
    console.warn(`[WARN] Correlation ${label} query failed: ${err.message}`);
    return [];
  }
}

function firstRow(rows, fallback = {}) {
  return rows && rows.length > 0 ? rows[0] : fallback;
}

function metricPointValue(dataPoint = {}) {
  if (dataPoint.asDouble !== undefined) return dataPoint.asDouble;
  if (dataPoint.asInt !== undefined) return dataPoint.asInt;
  if (dataPoint.value !== undefined) return dataPoint.value;
  if (dataPoint.sum !== undefined) return dataPoint.sum;
  return null;
}

function flattenMetricSamples(metricDocs = [], limit = 20) {
  const samples = [];

  for (const doc of metricDocs) {
    for (const resourceMetric of doc.resourceMetrics || []) {
      for (const scopeMetric of resourceMetric.scopeMetrics || []) {
        for (const metric of scopeMetric.metrics || []) {
          const dataPoints =
            metric.gauge?.dataPoints ||
            metric.sum?.dataPoints ||
            metric.histogram?.dataPoints ||
            [];

          for (const dataPoint of dataPoints) {
            samples.push({
              metricName: metric.name,
              unit: metric.unit,
              metricValue: metricPointValue(dataPoint),
              attributes: dataPoint.attributes,
              resourceAttributes: resourceMetric.resource?.attributes,
              timestampMs: dataPoint.timeUnixNano ? Math.floor(Number(dataPoint.timeUnixNano) / 1000000) : null
            });

            if (samples.length >= limit) {
              return samples;
            }
          }
        }
      }
    }
  }

  return samples;
}

async function fetchMetricSamples(limit = 20, { throwOnError = false } = {}) {
  const safeLimit = Math.max(1, Math.min(Number(limit) || 20, 50));
  let docs = [];
  try {
    docs = await runQuery(`
      SELECT mt.resourceMetrics
      FROM \`${bucketName}\`.\`${scopeName}\`.\`metrics\` mt
      WHERE ANY m WITHIN mt.resourceMetrics SATISFIES m.name IS NOT MISSING END
      LIMIT ${safeLimit}
    `);
  } catch (err) {
    console.warn(`[WARN] Metric sample query failed: ${err.message}`);
    if (throwOnError) throw err;
  }

  return flattenMetricSamples(docs, safeLimit);
}

function normalizeTimelineEvent({ id, type, severity = 'INFO', timestamp, title, subtitle, entityId, serviceName, traceId, details = {} }) {
  return {
    id,
    type,
    severity,
    timestamp,
    title,
    subtitle,
    entityId,
    serviceName,
    traceId,
    details
  };
}

const operatorQueryCatalog = [
  {
    id: 'collection-health',
    title: 'Recent data health',
    purpose: 'Confirm that recent demo data is present without scanning every document in every collection.',
    params: []
  },
  {
    id: 'incident-blast-radius',
    title: 'Incident blast radius',
    purpose: 'Show affected orders, customers, accounts, payment outcomes, tickets, and revenue at risk for one incident.',
    params: ['incidentId']
  },
  {
    id: 'service-payment-latency',
    title: 'Payment latency by service',
    purpose: 'Find which service is most associated with slow or failed payments for the selected incident.',
    params: ['incidentId']
  },
  {
    id: 'best-trace-candidates',
    title: 'Trace drill-in candidates',
    purpose: 'Find orders with linked payments and support tickets that make good trace-correlation examples.',
    params: ['incidentId']
  },
  {
    id: 'otel-coverage',
    title: 'OpenTelemetry coverage',
    purpose: 'Check how many trace and log records are available for business transactions in the selected incident.',
    params: ['incidentId']
  },
  {
    id: 'metrics-coverage',
    title: 'Metrics coverage',
    purpose: 'Show recent metric names, units, values, and attributes flowing through Kafka into Couchbase.',
    params: []
  },
  {
    id: 'high-value-accounts',
    title: 'High-value account impact',
    purpose: 'Rank accounts by affected orders, tickets, failed payments, and revenue impact.',
    params: ['incidentId']
  }
];

function operatorSqlText(lines) {
  return lines.map((line) => line.trim()).join('\n');
}

async function firstOperatorRow(label, sql, params = {}) {
  try {
    const rows = await runQuery(sql, params);
    return rows[0] || { check: label, status: 'empty', detail: 'No row matched the current demo context.' };
  } catch (err) {
    return { check: label, status: 'error', detail: err.message };
  }
}

async function limitedOperatorRows(label, sql, params = {}, mapRow = (row) => row) {
  try {
    const rows = await runQuery(sql, params);
    if (!rows || rows.length === 0) {
      return [{ check: label, status: 'empty', detail: 'No rows matched the current demo context.' }];
    }
    return rows.map((row) => ({ check: label, ...mapRow(row) }));
  } catch (err) {
    return [{ check: label, status: 'error', detail: err.message }];
  }
}

function requireOperatorParams(params, required) {
  const missing = required.filter((name) => !params[name]);
  if (missing.length > 0) {
    const error = new Error(`Missing required parameter(s): ${missing.join(', ')}`);
    error.statusCode = 400;
    throw error;
  }
}

async function executeOperatorQuery(queryId, params) {
  const definitions = {
    'collection-health': async () => {
      const orderIncidentFilter = params.incidentId ? 'WHERE o.incidentId = $incidentId' : 'WHERE o.incidentId IS NOT MISSING';
      const paymentIncidentFilter = params.incidentId ? 'WHERE p.incidentId = $incidentId' : 'WHERE p.incidentId IS NOT MISSING';
      const ticketIncidentFilter = params.incidentId ? 'WHERE t.incidentId = $incidentId' : 'WHERE t.incidentId IS NOT MISSING';
      const deploymentIncidentFilter = params.incidentId ? 'WHERE d.incidentId = $incidentId' : 'WHERE d.incidentId IS NOT MISSING';
      const checks = [
        firstOperatorRow('incidents', `
          SELECT 'incidents' AS collectionName, i.incidentId AS sampleId, i.status, i.startedAt AS lastSeen
          FROM \`${bucketName}\`.\`${scopeName}\`.incidents i
          WHERE i.startedAt IS NOT MISSING
          ORDER BY i.startedAt DESC
          LIMIT 1
        `, params),
        firstOperatorRow('orders', `
          SELECT 'orders' AS collectionName, o.orderId AS sampleId, o.status, o.orderTime AS lastSeen
          FROM \`${bucketName}\`.\`${scopeName}\`.orders o
          ${orderIncidentFilter}
          ORDER BY o.orderTime DESC
          LIMIT 1
        `, params),
        firstOperatorRow('payments', `
          SELECT 'payments' AS collectionName, p.paymentId AS sampleId, p.authorizationStatus AS status, p.createdTime AS lastSeen
          FROM \`${bucketName}\`.\`${scopeName}\`.payments p
          ${paymentIncidentFilter}
          ORDER BY p.createdTime DESC
          LIMIT 1
        `, params),
        firstOperatorRow('support_tickets', `
          SELECT 'support_tickets' AS collectionName, t.ticketId AS sampleId, t.status, t.createdTime AS lastSeen
          FROM \`${bucketName}\`.\`${scopeName}\`.support_tickets t
          ${ticketIncidentFilter}
          ORDER BY t.createdTime DESC
          LIMIT 1
        `, params),
        firstOperatorRow('deployments', `
          SELECT 'deployments' AS collectionName, d.deploymentId AS sampleId, d.status, d.timestamp AS lastSeen
          FROM \`${bucketName}\`.\`${scopeName}\`.deployments d
          ${deploymentIncidentFilter}
          ORDER BY d.timestamp DESC
          LIMIT 1
        `, params),
        params.traceId
          ? firstOperatorRow('otel traces', `
              SELECT 'traces' AS collectionName, s.traceId AS sampleId, s.name AS status,
                     DIV(TONUMBER(s.startTimeUnixNano), 1000000) AS lastSeen
              FROM \`${bucketName}\`.\`${scopeName}\`.traces tr
              UNNEST tr.resourceSpans AS rs
              UNNEST rs.scopeSpans AS ss
              UNNEST ss.spans AS s
              WHERE s.traceId = $traceId
              LIMIT 1
            `, params)
          : Promise.resolve({ check: 'otel traces', status: 'skipped', detail: 'Open a trace first to sample OTel spans without scanning.' })
      ];

      return {
        sql: operatorSqlText([
          'Bounded health check. Runs small indexed/sample queries instead of COUNT(*) scans.',
          'Uses the selected incidentId when available and traceId for OTel span sampling.'
        ]),
        rows: await Promise.all(checks)
      };
    },
    'incident-blast-radius': async () => {
      requireOperatorParams(params, ['incidentId']);
      const [orders, payments, tickets] = await Promise.all([
        limitedOperatorRows('recent affected orders', `
          SELECT o.orderId, o.customerId, o.accountId, o.status, ROUND(o.totalAmount, 2) AS totalAmount, o.orderTime
          FROM \`${bucketName}\`.\`${scopeName}\`.orders o
          WHERE o.incidentId = $incidentId
          ORDER BY o.orderTime DESC
          LIMIT 8
        `, params),
        limitedOperatorRows('recent payment issues', `
          SELECT p.paymentId, p.orderId, p.accountId, p.authorizationStatus, p.latencyMs, p.createdTime
          FROM \`${bucketName}\`.\`${scopeName}\`.payments p
          WHERE p.incidentId = $incidentId
          ORDER BY p.createdTime DESC
          LIMIT 8
        `, params),
        limitedOperatorRows('recent support tickets', `
          SELECT t.ticketId, t.customerId, t.accountId, t.status, t.severity, t.createdTime
          FROM \`${bucketName}\`.\`${scopeName}\`.support_tickets t
          WHERE t.incidentId = $incidentId
          ORDER BY t.createdTime DESC
          LIMIT 8
        `, params)
      ]);

      return {
        sql: operatorSqlText([
          'Bounded blast-radius sampler:',
          'orders WHERE incidentId = $incidentId ORDER BY orderTime DESC LIMIT 8',
          'payments WHERE incidentId = $incidentId ORDER BY createdTime DESC LIMIT 8',
          'support_tickets WHERE incidentId = $incidentId ORDER BY createdTime DESC LIMIT 8'
        ]),
        rows: [...orders, ...payments, ...tickets]
      };
    },
    'service-payment-latency': async () => {
      requireOperatorParams(params, ['incidentId']);
      const rows = await limitedOperatorRows('recent payment latency', `
        SELECT p.paymentId, p.orderId, p.serviceName, p.authorizationStatus, p.latencyMs, p.processor, p.createdTime
        FROM \`${bucketName}\`.\`${scopeName}\`.payments p
        WHERE p.incidentId = $incidentId
        ORDER BY p.createdTime DESC
        LIMIT 15
      `, params);

      return {
        sql: 'SELECT recent payments for the selected incident ordered by createdTime DESC LIMIT 15.',
        rows
      };
    },
    'best-trace-candidates': async () => {
      requireOperatorParams(params, ['incidentId']);
      const rows = await limitedOperatorRows('trace candidates', `
        SELECT o.orderId, o.traceId, o.customerId, o.accountId, o.status, ROUND(o.totalAmount, 2) AS totalAmount, o.orderTime
        FROM \`${bucketName}\`.\`${scopeName}\`.orders o
        WHERE o.incidentId = $incidentId
          AND o.traceId IS NOT MISSING
        ORDER BY o.orderTime DESC
        LIMIT 12
      `, params);

      return {
        sql: 'SELECT recent orders with traceId for the selected incident. Bounded to 12 rows.',
        rows
      };
    },
    'otel-coverage': async () => {
      requireOperatorParams(params, ['incidentId']);
      const traceRows = await runQuery(`
        SELECT RAW o.traceId
        FROM \`${bucketName}\`.\`${scopeName}\`.orders o
        WHERE o.incidentId = $incidentId AND o.traceId IS NOT MISSING
        LIMIT 10
      `, params);
      const traceIds = [...new Set(traceRows.filter(Boolean))];

      if (traceIds.length === 0) {
        return {
          sql: 'Fetch up to 25 incident trace IDs, then count matching OTel spans/logs.',
          rows: [{ signal: 'business traces', count: 0, detail: 'No business trace IDs found for this incident.' }]
        };
      }

      const coverageParams = { traceIds };
      const [spans, logs] = await Promise.all([
        limitedOperatorRows('otel span samples', `
          SELECT s.traceId, s.name AS spanName, s.spanId,
                 DIV(TONUMBER(s.endTimeUnixNano) - TONUMBER(s.startTimeUnixNano), 1000000) AS durationMs
          FROM \`${bucketName}\`.\`${scopeName}\`.traces tr
          UNNEST tr.resourceSpans AS rs
          UNNEST rs.scopeSpans AS ss
          UNNEST ss.spans AS s
          WHERE s.traceId IN $traceIds
          LIMIT 10
        `, coverageParams),
        limitedOperatorRows('otel log samples', `
          SELECT lr.traceId, lr.severityText AS severity, lr.body.stringValue AS message,
                 DIV(TONUMBER(lr.timeUnixNano), 1000000) AS timestampMs
          FROM \`${bucketName}\`.\`${scopeName}\`.\`logs\` lg
          UNNEST lg.resourceLogs AS rl
          UNNEST rl.scopeLogs AS sl
          UNNEST sl.logRecords AS lr
          WHERE ANY x WITHIN lg.resourceLogs SATISFIES x.traceId IN $traceIds END
            AND lr.traceId IN $traceIds
          LIMIT 10
        `, coverageParams)
      ]);

      return {
        sql: operatorSqlText([
          'SELECT RAW traceId FROM orders WHERE incidentId = $incidentId LIMIT 10;',
          'Then fetch bounded OTel span/log samples for only those trace IDs.'
        ]),
        rows: [
          { check: 'sampled business traces', traceSampleCount: traceIds.length, traceIds: traceIds.join(', ') },
          ...spans,
          ...logs
        ]
      };
    },
    'high-value-accounts': async () => {
      requireOperatorParams(params, ['incidentId']);
      const orderAccounts = await runQuery(`
        SELECT RAW o.accountId
        FROM \`${bucketName}\`.\`${scopeName}\`.orders o
        WHERE o.incidentId = $incidentId AND o.accountId IS NOT MISSING
        LIMIT 25
      `, params);
      const accountIds = [...new Set(orderAccounts.filter(Boolean))].slice(0, 25);

      if (accountIds.length === 0) {
        return {
          sql: 'Fetch account IDs from recent incident orders, then fetch account profiles.',
          rows: [{ check: 'high-value accounts', status: 'empty', detail: 'No account IDs found for this incident.' }]
        };
      }

      const rows = await limitedOperatorRows('high-value account profiles', `
        SELECT a.accountId, a.name, a.slaTier, a.annualRecurringRevenue, a.accountOwner, a.region
        FROM \`${bucketName}\`.\`${scopeName}\`.accounts a
        WHERE a.accountId IN $accountIds
        ORDER BY a.annualRecurringRevenue DESC
        LIMIT 10
      `, { accountIds });

      return {
        sql: operatorSqlText([
          'SELECT RAW accountId FROM orders WHERE incidentId = $incidentId LIMIT 25;',
          'SELECT account profiles WHERE accountId IN sampled account IDs ORDER BY ARR DESC LIMIT 10;'
        ]),
        rows
      };
    },
    'metrics-coverage': async () => {
      const rows = await fetchMetricSamples(20, { throwOnError: true });

      return {
        sql: operatorSqlText([
          'SELECT resourceMetrics from a bounded set of metric documents where nested metric names exist.',
          'The API then flattens resourceMetrics -> scopeMetrics -> metrics -> dataPoints in Node to handle OTel payload variations.'
        ]),
        rows
      };
    }
  };

  const definition = definitions[queryId];
  if (!definition) return null;

  if (typeof definition === 'function') {
    return await definition();
  }

  const error = new Error('Operator query is not executable.');
  error.statusCode = 500;
  throw error;
}

function buildTimelinePredicate(alias, filters) {
  const clauses = [];
  const params = {};

  for (const key of ['incidentId', 'traceId', 'orderId', 'customerId', 'accountId']) {
    if (filters[key]) {
      clauses.push(`${alias}.${key} = $${key}`);
      params[key] = filters[key];
    }
  }

  return {
    where: clauses.length > 0 ? clauses.join(' AND ') : null,
    params
  };
}

function buildRecommendedAction({ account, customer, orderImpact = {}, ticketImpact = {}, paymentImpact = [] }) {
  const slaTier = account?.slaTier || customer?.slaTier || 'Unknown';
  const revenueAtRisk = Number(orderImpact.revenueAtRisk || 0);
  const openTickets = Number(ticketImpact.openTickets || 0);
  const slaRisks = Number(ticketImpact.slaBreachRisks || 0);
  const declinedPayments = paymentImpact
    .filter(row => row.authorizationStatus === 'DECLINED')
    .reduce((sum, row) => sum + Number(row.attempts || 0), 0);

  if (slaTier === 'Platinum' && (revenueAtRisk > 10000 || slaRisks > 0)) {
    return {
      priority: 'Executive Escalation',
      action: 'Assign account owner and support leadership immediately; prepare proactive customer communication.',
      reason: 'Platinum SLA with material revenue or SLA breach risk.'
    };
  }

  if (declinedPayments > 0 || openTickets > 5) {
    return {
      priority: 'High Touch Support',
      action: 'Open a support bridge, monitor failed payments, and queue remediation for impacted orders.',
      reason: 'Payment failures or elevated support volume are visible for this entity.'
    };
  }

  if (revenueAtRisk > 0) {
    return {
      priority: 'Monitor And Follow Up',
      action: 'Monitor recovery and prepare follow-up for affected customers if errors continue.',
      reason: 'Business impact is present but current escalation signals are moderate.'
    };
  }

  return {
    priority: 'Observe',
    action: 'No immediate escalation required; continue monitoring for new impact.',
    reason: 'No significant current revenue, payment, or SLA risk detected.'
  };
}

function rankRootCauseServices({ incident, serviceSignals = [], deployments = [] }) {
  const affectedServices = incident?.affectedServices || [];
  const deploymentByService = new Map(deployments.map(deployment => [deployment.serviceName, deployment]));

  const ranked = serviceSignals.map(signal => {
    const deployment = deploymentByService.get(signal.serviceName);
    const failedPayments = Number(signal.failedPayments || 0);
    const slowPayments = Number(signal.slowPayments || 0);
    const impactedOrders = Number(signal.impactedOrders || 0);
    const supportTickets = Number(signal.supportTickets || 0);
    const avgLatencyMs = Number(signal.avgLatencyMs || 0);
    const score =
      failedPayments * 5 +
      slowPayments * 3 +
      supportTickets * 4 +
      impactedOrders +
      (avgLatencyMs >= 800 ? 8 : 0) +
      (deployment?.changeRisk === 'HIGH' ? 12 : 0) +
      (affectedServices.includes(signal.serviceName) ? 10 : 0);

    return {
      ...signal,
      deployment,
      score,
      confidence: score >= 40 ? 'High' : (score >= 15 ? 'Medium' : 'Low')
    };
  });

  ranked.sort((a, b) => b.score - a.score);
  return ranked;
}

function sumNumber(rows, field) {
  return rows.reduce((sum, row) => sum + Number(row[field] || 0), 0);
}

function uniqueCount(rows, field) {
  return new Set(rows.map(row => row[field]).filter(Boolean)).size;
}

function groupCount(rows, field, countField = 'count') {
  const counts = new Map();
  for (const row of rows) {
    const key = row[field] || 'UNKNOWN';
    counts.set(key, (counts.get(key) || 0) + 1);
  }
  return [...counts.entries()]
    .map(([key, count]) => ({ [field]: key, [countField]: count }))
    .sort((a, b) => b[countField] - a[countField]);
}

function summarizePayments(payments) {
  const grouped = new Map();
  for (const payment of payments) {
    const status = payment.authorizationStatus || 'UNKNOWN';
    const existing = grouped.get(status) || { authorizationStatus: status, attempts: 0, totalLatency: 0, maxLatencyMs: 0 };
    const latency = Number(payment.latencyMs || 0);
    existing.attempts += 1;
    existing.totalLatency += latency;
    existing.maxLatencyMs = Math.max(existing.maxLatencyMs, latency);
    grouped.set(status, existing);
  }
  return [...grouped.values()]
    .map(row => ({
      authorizationStatus: row.authorizationStatus,
      attempts: row.attempts,
      avgLatencyMs: row.attempts > 0 ? Math.round((row.totalLatency / row.attempts) * 100) / 100 : 0,
      maxLatencyMs: row.maxLatencyMs
    }))
    .sort((a, b) => b.attempts - a.attempts);
}

function summarizeTickets(tickets) {
  return {
    openTickets: tickets.length,
    affectedTicketAccounts: uniqueCount(tickets, 'accountId'),
    slaBreachRisks: tickets.filter(ticket => ticket.slaBreachRisk === true).length,
    issueTypes: [...new Set(tickets.map(ticket => ticket.issueType).filter(Boolean))],
    recentTickets: tickets.slice(0, 10)
  };
}

// ------------------------------------------------------------------------------
// API Endpoints
// ------------------------------------------------------------------------------

// 1. Incident Command Center cards
app.get('/api/incidents', async (req, res) => {
  try {
    const n1ql = `
      SELECT i.incidentId,
             i.scenario,
             i.title,
             i.severity,
             i.status,
             i.affectedServices,
             i.affectedRegions,
             i.estimatedRevenueImpact,
             i.actualRevenueAtRisk,
             i.affectedOrderCount,
             i.affectedCustomerCount,
             i.startedAt,
             i.updatedTime,
             i.ownerTeam
      FROM \`${bucketName}\`.\`${scopeName}\`.incidents i
      WHERE i.startedAt IS NOT MISSING
      ORDER BY i.startedAt DESC
      LIMIT 12
    `;
    const incidents = await runQuery(n1ql);
    res.json(incidents);
  } catch (err) {
    console.error('[API Error] Incidents error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// 2. Incident summary endpoint for Command Center detail view
app.get('/api/incidents/:incidentId/summary', async (req, res) => {
  const { incidentId } = req.params;
  const params = { incidentId };

  try {
    const incidentQuery = `
      SELECT i.*
      FROM \`${bucketName}\`.\`${scopeName}\`.incidents i
      WHERE i.incidentId = $incidentId
      LIMIT 1
    `;

    const paymentSampleQuery = `
      SELECT p.paymentId, p.orderId, p.accountId, p.authorizationStatus, p.latencyMs, p.createdTime
      FROM \`${bucketName}\`.\`${scopeName}\`.payments p
      WHERE p.incidentId = $incidentId
      ORDER BY p.createdTime DESC
      LIMIT 300
    `;

    const ticketSampleQuery = `
      SELECT t.ticketId, t.accountId, t.customerId, t.issueType, t.severity, t.sentiment, t.slaBreachRisk, t.status, t.createdTime
      FROM \`${bucketName}\`.\`${scopeName}\`.support_tickets t
      WHERE t.incidentId = $incidentId
      ORDER BY t.createdTime DESC
      LIMIT 300
    `;

    const accountOrderSampleQuery = `
      SELECT o.orderId, o.accountId, o.accountName, o.totalAmount
      FROM \`${bucketName}\`.\`${scopeName}\`.orders o
      WHERE o.incidentId = $incidentId
      ORDER BY o.orderTime DESC
      LIMIT 300
    `;

    const recentOrdersQuery = `
      SELECT o.orderId,
             o.customerId,
             o.accountId,
             o.accountName,
             o.traceId,
             o.status,
             o.totalAmount,
             o.serviceName,
             o.region,
             o.orderTime
      FROM \`${bucketName}\`.\`${scopeName}\`.orders o
      WHERE o.incidentId = $incidentId
      ORDER BY o.orderTime DESC
      LIMIT 10
    `;

    const deploymentsQuery = `
      SELECT d.deploymentId,
             d.serviceName,
             d.version,
             d.status,
             d.changeRisk,
             d.deployedBy,
             d.timestamp
      FROM \`${bucketName}\`.\`${scopeName}\`.deployments d
      WHERE d.incidentId = $incidentId
      ORDER BY d.timestamp DESC
      LIMIT 8
    `;

    const incidentRows = await runQueryOrEmpty('incident', incidentQuery, params);
    const incident = firstRow(incidentRows, null);
    if (!incident) {
      return res.status(404).json({ error: `Incident not found: ${incidentId}` });
    }

    const [paymentSamples, ticketSamples, accountOrderSamples, recentOrders, deployments] = await Promise.all([
      runQueryOrEmpty('incident payment samples', paymentSampleQuery, params),
      runQueryOrEmpty('incident ticket samples', ticketSampleQuery, params),
      runQueryOrEmpty('incident account order samples', accountOrderSampleQuery, params),
      runQueryOrEmpty('incident recent orders', recentOrdersQuery, params),
      runQueryOrEmpty('incident deployments', deploymentsQuery, params)
    ]);

    const accountRollups = new Map();
    for (const order of accountOrderSamples) {
      if (!order.accountId) continue;
      const rollup = accountRollups.get(order.accountId) || {
        accountId: order.accountId,
        name: order.accountName,
        affectedOrders: 0,
        revenueAtRisk: 0
      };
      rollup.affectedOrders += 1;
      rollup.revenueAtRisk += Number(order.totalAmount || 0);
      accountRollups.set(order.accountId, rollup);
    }

    const topAccountRollups = [...accountRollups.values()]
      .sort((a, b) => b.revenueAtRisk - a.revenueAtRisk)
      .slice(0, 5);
    const topAccountIds = topAccountRollups.map(account => account.accountId);
    const accountProfiles = topAccountIds.length > 0
      ? await runQueryOrEmpty('incident top account profiles', `
          SELECT a.accountId, a.name, a.slaTier, a.annualRecurringRevenue
          FROM \`${bucketName}\`.\`${scopeName}\`.accounts a
          WHERE a.accountId IN $accountIds
        `, { accountIds: topAccountIds })
      : [];
    const accountProfilesById = new Map(accountProfiles.map(account => [account.accountId, account]));
    const topAccounts = topAccountRollups.map(rollup => ({
      ...rollup,
      ...accountProfilesById.get(rollup.accountId),
      revenueAtRisk: Math.round(rollup.revenueAtRisk * 100) / 100
    }));
    const paymentImpact = summarizePayments(paymentSamples);
    const ticketImpact = summarizeTickets(ticketSamples);

    res.json({
      incident,
      orderImpact: {
        affectedOrders: incident.affectedOrderCount || 0,
        affectedCustomers: incident.affectedCustomerCount || 0,
        affectedAccounts: topAccounts.length,
        revenueAtRisk: incident.actualRevenueAtRisk || incident.estimatedRevenueImpact || 0,
        services: incident.affectedServices || [],
        regions: incident.affectedRegions || []
      },
      paymentImpact,
      ticketImpact,
      topAccounts,
      recentOrders,
      deployments
    });
  } catch (err) {
    console.error('[API Error] Incident summary error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// 3. Account 360 impact view
app.get('/api/accounts/:accountId/impact', async (req, res) => {
  const { accountId } = req.params;
  const params = { accountId };

  try {
    const accountQuery = `
      SELECT a.*
      FROM \`${bucketName}\`.\`${scopeName}\`.accounts a
      WHERE a.accountId = $accountId
      LIMIT 1
    `;

    const customerSamplesQuery = `
      SELECT c.customerId, c.name, c.email, c.slaTier
      FROM \`${bucketName}\`.\`${scopeName}\`.customers c
      WHERE c.accountId = $accountId
      LIMIT 25
    `;

    const recentOrdersQuery = `
      SELECT o.orderId, o.customerId, o.incidentId, o.traceId, o.status, o.totalAmount, o.serviceName, o.region, o.orderTime
      FROM \`${bucketName}\`.\`${scopeName}\`.orders o
      WHERE o.accountId = $accountId
      ORDER BY o.orderTime DESC
      LIMIT 10
    `;

    const paymentSamplesQuery = `
      SELECT p.paymentId, p.orderId, p.authorizationStatus, p.latencyMs, p.createdTime
      FROM \`${bucketName}\`.\`${scopeName}\`.payments p
      WHERE p.accountId = $accountId
      ORDER BY p.createdTime DESC
      LIMIT 300
    `;

    const ticketSamplesQuery = `
      SELECT t.ticketId, t.issueType, t.severity, t.sentiment, t.slaBreachRisk, t.status, t.createdTime
      FROM \`${bucketName}\`.\`${scopeName}\`.support_tickets t
      WHERE t.accountId = $accountId
      ORDER BY t.createdTime DESC
      LIMIT 150
    `;

    const shipmentSamplesQuery = `
      SELECT s.shipmentId, s.status, s.createdTime
      FROM \`${bucketName}\`.\`${scopeName}\`.shipments s
      WHERE s.accountId = $accountId
      ORDER BY s.createdTime DESC
      LIMIT 300
    `;

    const [accountRows, customerSamples, recentOrders, paymentSamples, ticketSamples, shipmentSamples] = await Promise.all([
      runQueryOrEmpty('account impact profile', accountQuery, params),
      runQueryOrEmpty('account impact customer samples', customerSamplesQuery, params),
      runQueryOrEmpty('account impact recent orders', recentOrdersQuery, params),
      runQueryOrEmpty('account impact payment samples', paymentSamplesQuery, params),
      runQueryOrEmpty('account impact ticket samples', ticketSamplesQuery, params),
      runQueryOrEmpty('account impact shipment samples', shipmentSamplesQuery, params)
    ]);

    const account = firstRow(accountRows, { accountId });
    const orderImpact = {
      orderCount: recentOrders.length,
      totalOrderValue: Math.round(sumNumber(recentOrders, 'totalAmount') * 100) / 100,
      incidentCount: uniqueCount(recentOrders, 'incidentId'),
      orderStatuses: [...new Set(recentOrders.map(order => order.status).filter(Boolean))]
    };
    const ticketImpact = summarizeTickets(ticketSamples);
    const customerImpact = { customerCount: customerSamples.length, sampleCustomers: customerSamples.slice(0, 10) };
    const paymentImpact = summarizePayments(paymentSamples);
    const shipmentImpact = groupCount(shipmentSamples, 'status', 'shipments').slice(0, 8);

    res.json({
      type: 'account',
      account,
      customerImpact,
      orderImpact,
      recentOrders,
      paymentImpact,
      ticketImpact,
      shipmentImpact,
      recommendedAction: buildRecommendedAction({ account, orderImpact: { revenueAtRisk: orderImpact.totalOrderValue }, ticketImpact, paymentImpact })
    });
  } catch (err) {
    console.error('[API Error] Account impact error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// 4. Customer 360 impact view
app.get('/api/customers/:customerId/impact', async (req, res) => {
  const { customerId } = req.params;
  const params = { customerId };

  try {
    const customerQuery = `
      SELECT c.*
      FROM \`${bucketName}\`.\`${scopeName}\`.customers c
      WHERE c.customerId = $customerId
      LIMIT 1
    `;

    const recentOrdersQuery = `
      SELECT o.orderId, o.accountId, o.accountName, o.incidentId, o.traceId, o.status, o.totalAmount, o.serviceName, o.region, o.orderTime
      FROM \`${bucketName}\`.\`${scopeName}\`.orders o
      WHERE o.customerId = $customerId
      ORDER BY o.orderTime DESC
      LIMIT 10
    `;

    const paymentSamplesQuery = `
      SELECT p.paymentId, p.orderId, p.authorizationStatus, p.latencyMs, p.createdTime
      FROM \`${bucketName}\`.\`${scopeName}\`.payments p
      WHERE p.customerId = $customerId
      ORDER BY p.createdTime DESC
      LIMIT 200
    `;

    const ticketSamplesQuery = `
      SELECT t.ticketId, t.issueType, t.severity, t.sentiment, t.slaBreachRisk, t.status, t.createdTime
      FROM \`${bucketName}\`.\`${scopeName}\`.support_tickets t
      WHERE t.customerId = $customerId
      ORDER BY t.createdTime DESC
      LIMIT 100
    `;

    const shipmentSamplesQuery = `
      SELECT s.shipmentId, s.status, s.createdTime
      FROM \`${bucketName}\`.\`${scopeName}\`.shipments s
      WHERE s.customerId = $customerId
      ORDER BY s.createdTime DESC
      LIMIT 200
    `;

    const [customerRows, recentOrders, paymentSamples, ticketSamples, shipmentSamples] = await Promise.all([
      runQueryOrEmpty('customer impact profile', customerQuery, params),
      runQueryOrEmpty('customer impact recent orders', recentOrdersQuery, params),
      runQueryOrEmpty('customer impact payment samples', paymentSamplesQuery, params),
      runQueryOrEmpty('customer impact ticket samples', ticketSamplesQuery, params),
      runQueryOrEmpty('customer impact shipment samples', shipmentSamplesQuery, params)
    ]);

    const customer = firstRow(customerRows, { customerId });
    const orderImpact = {
      orderCount: recentOrders.length,
      totalOrderValue: Math.round(sumNumber(recentOrders, 'totalAmount') * 100) / 100,
      incidentCount: uniqueCount(recentOrders, 'incidentId'),
      orderStatuses: [...new Set(recentOrders.map(order => order.status).filter(Boolean))]
    };
    const ticketImpact = summarizeTickets(ticketSamples);
    const paymentImpact = summarizePayments(paymentSamples);
    const shipmentImpact = groupCount(shipmentSamples, 'status', 'shipments').slice(0, 8);

    res.json({
      type: 'customer',
      customer,
      orderImpact,
      recentOrders,
      paymentImpact,
      ticketImpact,
      shipmentImpact,
      recommendedAction: buildRecommendedAction({ customer, orderImpact: { revenueAtRisk: orderImpact.totalOrderValue }, ticketImpact, paymentImpact })
    });
  } catch (err) {
    console.error('[API Error] Customer impact error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// 5. Root cause evidence for an incident
app.get('/api/incidents/:incidentId/root-cause', async (req, res) => {
  const { incidentId } = req.params;
  const params = { incidentId };

  try {
    const incidentQuery = `
      SELECT i.*
      FROM \`${bucketName}\`.\`${scopeName}\`.incidents i
      WHERE i.incidentId = $incidentId
      LIMIT 1
    `;

    const deploymentsQuery = `
      SELECT d.deploymentId, d.serviceName, d.version, d.status, d.changeRisk,
             d.deployedBy, d.\`commit\`, d.region, d.timestamp
      FROM \`${bucketName}\`.\`${scopeName}\`.deployments d
      WHERE d.incidentId = $incidentId
      ORDER BY d.timestamp DESC
      LIMIT 20
    `;

    const orderSignalsQuery = `
      WITH recent_orders AS (
        SELECT o.serviceName, o.orderId, o.traceId, o.status, o.totalAmount
        FROM \`${bucketName}\`.\`${scopeName}\`.orders o
        WHERE o.incidentId = $incidentId
        ORDER BY o.orderTime DESC
        LIMIT 1000
      )
      SELECT IFMISSINGORNULL(o.serviceName, "unknown") AS serviceName,
             COUNT(DISTINCT o.orderId) AS impactedOrders,
             COUNT(DISTINCT o.traceId) AS traceCount,
             ROUND(SUM(o.totalAmount), 2) AS revenueAtRisk,
             ARRAY_AGG(DISTINCT o.status) AS orderStatuses
      FROM recent_orders o
      GROUP BY IFMISSINGORNULL(o.serviceName, "unknown")
    `;

    const paymentSignalsQuery = `
      WITH recent_payments AS (
        SELECT p.serviceName, p.paymentId, p.orderId, p.traceId, p.authorizationStatus,
               p.declineReason, p.latencyMs, p.createdTime
        FROM \`${bucketName}\`.\`${scopeName}\`.payments p
        WHERE p.incidentId = $incidentId
        ORDER BY p.createdTime DESC
        LIMIT 1000
      )
      SELECT IFMISSINGORNULL(p.serviceName, "unknown") AS serviceName,
             COUNT(1) AS paymentAttempts,
             SUM(CASE WHEN p.authorizationStatus = "DECLINED" THEN 1 ELSE 0 END) AS failedPayments,
             SUM(CASE WHEN p.latencyMs >= 800 THEN 1 ELSE 0 END) AS slowPayments,
             ROUND(AVG(p.latencyMs), 2) AS avgLatencyMs,
             MAX(p.latencyMs) AS maxLatencyMs,
             ARRAY_AGG({"traceId": p.traceId, "orderId": p.orderId, "authorizationStatus": p.authorizationStatus, "declineReason": p.declineReason, "latencyMs": p.latencyMs, "createdTime": p.createdTime})[0:8] AS representativePayments
      FROM recent_payments p
      GROUP BY IFMISSINGORNULL(p.serviceName, "unknown")
    `;

    const ticketSignalsQuery = `
      WITH recent_tickets AS (
        SELECT t.serviceName, t.ticketId, t.traceId, t.issueType, t.severity, t.sentiment,
               t.slaBreachRisk, t.createdTime
        FROM \`${bucketName}\`.\`${scopeName}\`.support_tickets t
        WHERE t.incidentId = $incidentId
        ORDER BY t.createdTime DESC
        LIMIT 1000
      )
      SELECT IFMISSINGORNULL(t.serviceName, "unknown") AS serviceName,
             COUNT(1) AS supportTickets,
             SUM(CASE WHEN t.slaBreachRisk = TRUE THEN 1 ELSE 0 END) AS slaBreachRisks,
             ARRAY_AGG(DISTINCT t.issueType) AS issueTypes,
             ARRAY_AGG({"ticketId": t.ticketId, "traceId": t.traceId, "issueType": t.issueType, "severity": t.severity, "sentiment": t.sentiment, "createdTime": t.createdTime})[0:8] AS representativeTickets
      FROM recent_tickets t
      GROUP BY IFMISSINGORNULL(t.serviceName, "unknown")
    `;

    const representativeTracesQuery = `
      SELECT p.traceId, p.orderId, p.serviceName, p.authorizationStatus, p.declineReason,
             p.latencyMs, p.createdTime
      FROM \`${bucketName}\`.\`${scopeName}\`.payments p
      WHERE p.incidentId = $incidentId
        AND (p.authorizationStatus = "DECLINED" OR p.latencyMs >= 800)
      ORDER BY p.createdTime DESC
      LIMIT 10
    `;

    const [incidentRows, deployments, orderSignals, paymentSignals, ticketSignals, representativeTraces] = await Promise.all([
      runQueryOrEmpty('root cause incident', incidentQuery, params),
      runQueryOrEmpty('root cause deployments', deploymentsQuery, params),
      runQueryOrEmpty('root cause order signals', orderSignalsQuery, params),
      runQueryOrEmpty('root cause payment signals', paymentSignalsQuery, params),
      runQueryOrEmpty('root cause ticket signals', ticketSignalsQuery, params),
      runQueryOrEmpty('root cause representative traces', representativeTracesQuery, params)
    ]);

    const incident = firstRow(incidentRows, null);
    if (!incident) {
      return res.status(404).json({ error: `Incident not found: ${incidentId}` });
    }

    const signalMap = new Map();
    const mergeSignal = (row) => {
      const serviceName = row.serviceName || 'unknown';
      signalMap.set(serviceName, {
        ...(signalMap.get(serviceName) || { serviceName }),
        ...row
      });
    };
    orderSignals.forEach(mergeSignal);
    paymentSignals.forEach(mergeSignal);
    ticketSignals.forEach(mergeSignal);
    for (const serviceName of incident.affectedServices || []) {
      if (!signalMap.has(serviceName)) {
        signalMap.set(serviceName, { serviceName });
      }
    }

    const rankedServices = rankRootCauseServices({
      incident,
      serviceSignals: [...signalMap.values()],
      deployments
    });
    const suspectedService = rankedServices[0] || null;
    const serviceNames = [...new Set([
      ...(incident.affectedServices || []),
      ...rankedServices.slice(0, 5).map(service => service.serviceName),
      ...deployments.map(deployment => deployment.serviceName)
    ].filter(Boolean))];

    let serviceProfiles = [];
    if (serviceNames.length > 0) {
      const servicesQuery = `
        SELECT s.serviceId, s.serviceName, s.ownerTeam, s.sloTargetMs, s.dependencies,
               s.currentVersion, s.region, s.status
        FROM \`${bucketName}\`.\`${scopeName}\`.services s
        WHERE s.serviceName IN $serviceNames
      `;
      serviceProfiles = await runQueryOrEmpty('root cause service profiles', servicesQuery, { serviceNames });
    }

    const suspectedProfile = serviceProfiles.find(service => service.serviceName === suspectedService?.serviceName) || null;
    const downstreamServices = suspectedProfile?.dependencies || [];

    const traceIds = [...new Set(representativeTraces.map(trace => trace.traceId).filter(Boolean))].slice(0, 8);
    let keyLogs = [];
    let spanEvidence = [];
    const metricEvidencePromise = fetchMetricSamples(12);

    if (traceIds.length > 0) {
      const logsQuery = `
        SELECT lr.traceId,
               lr.severityText AS severity,
               lr.body.stringValue AS logMessage,
               DIV(TONUMBER(lr.timeUnixNano), 1000000) AS timestampMs
        FROM \`${bucketName}\`.\`${scopeName}\`.\`logs\` l
        UNNEST l.resourceLogs AS rl
        UNNEST rl.scopeLogs AS sl
        UNNEST sl.logRecords AS lr
        WHERE ANY x WITHIN l.resourceLogs SATISFIES x.traceId IN $traceIds END
          AND lr.traceId IN $traceIds
        ORDER BY lr.timeUnixNano DESC
        LIMIT 20
      `;

      const spansQuery = `
        SELECT s.traceId,
               s.name AS spanName,
               s.spanId,
               DIV(TONUMBER(s.startTimeUnixNano), 1000000) AS startTimeMs,
               DIV(TONUMBER(s.endTimeUnixNano) - TONUMBER(s.startTimeUnixNano), 1000000) AS durationMs,
               s.attributes
        FROM \`${bucketName}\`.\`${scopeName}\`.traces t
        UNNEST t.resourceSpans AS rs
        UNNEST rs.scopeSpans AS ss
        UNNEST ss.spans AS s
        WHERE s.traceId IN $traceIds
        ORDER BY durationMs DESC
        LIMIT 20
      `;

      [keyLogs, spanEvidence] = await Promise.all([
        runQueryOrEmpty('root cause logs', logsQuery, { traceIds }),
        runQueryOrEmpty('root cause spans', spansQuery, { traceIds })
      ]);
    }
    const metricEvidence = await metricEvidencePromise;

    res.json({
      incident,
      suspectedService,
      suspectedProfile,
      serviceSignals: rankedServices,
      deployments,
      representativeTraces,
      keyLogs,
      spanEvidence,
      metricEvidence,
      affectedDownstreamServices: downstreamServices,
      evidenceSummary: {
        deploymentCount: deployments.length,
        representativeTraceCount: representativeTraces.length,
        logCount: keyLogs.length,
        spanCount: spanEvidence.length,
        metricCount: metricEvidence.length,
        affectedServiceCount: serviceNames.length
      }
    });
  } catch (err) {
    console.error('[API Error] Root cause error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// 6. Best demo records for presenter guidance
app.get('/api/demo/best-records', async (req, res) => {
  try {
    const incidentQuery = `
      SELECT i.incidentId, i.scenario, i.title, i.severity, i.status,
             i.affectedServices, i.actualRevenueAtRisk, i.estimatedRevenueImpact,
             i.affectedOrderCount, i.affectedCustomerCount, i.startedAt, i.ownerTeam
      FROM \`${bucketName}\`.\`${scopeName}\`.incidents i
      WHERE i.startedAt IS NOT MISSING
      ORDER BY CASE WHEN IFMISSINGORNULL(i.affectedOrderCount, 0) > 0 THEN 0 ELSE 1 END,
               CASE WHEN i.incidentId = "INC-DEMO-001" THEN 0 ELSE 1 END,
               IFMISSINGORNULL(i.affectedOrderCount, 0) DESC,
               IFMISSINGORNULL(i.actualRevenueAtRisk, IFMISSINGORNULL(i.estimatedRevenueImpact, 0)) DESC,
               i.startedAt DESC
      LIMIT 1
    `;

    const incident = firstRow(await runQueryOrEmpty('best records incident', incidentQuery), null);
    if (!incident) {
      return res.json({
        ready: false,
        message: 'No incident records found yet. Wait for the generator to publish incidents.',
        incident: null
      });
    }

    const params = { incidentId: incident.incidentId };
    const accountQuery = `
      WITH recent_orders AS (
        SELECT o.orderId, o.accountId, o.totalAmount
        FROM \`${bucketName}\`.\`${scopeName}\`.orders o
        WHERE o.incidentId = $incidentId
        ORDER BY o.orderTime DESC
        LIMIT 1000
      )
      SELECT a.accountId, a.name, a.slaTier, a.annualRecurringRevenue,
             COUNT(DISTINCT o.orderId) AS affectedOrders,
             ROUND(SUM(o.totalAmount), 2) AS revenueAtRisk
      FROM recent_orders o
      LEFT JOIN \`${bucketName}\`.\`${scopeName}\`.accounts a ON a.accountId = o.accountId
      GROUP BY a.accountId, a.name, a.slaTier, a.annualRecurringRevenue
      ORDER BY revenueAtRisk DESC, affectedOrders DESC
      LIMIT 1
    `;

    const customerQuery = `
      WITH recent_orders AS (
        SELECT o.orderId, o.customerId, o.accountId, o.accountName, o.totalAmount
        FROM \`${bucketName}\`.\`${scopeName}\`.orders o
        WHERE o.incidentId = $incidentId
        ORDER BY o.orderTime DESC
        LIMIT 1000
      )
      SELECT c.customerId, c.name, c.email, c.slaTier, c.accountId,
             COUNT(DISTINCT o.orderId) AS orderCount,
             ROUND(SUM(o.totalAmount), 2) AS revenueAtRisk
      FROM recent_orders o
      LEFT JOIN \`${bucketName}\`.\`${scopeName}\`.customers c ON c.customerId = o.customerId
      GROUP BY c.customerId, c.name, c.email, c.slaTier, c.accountId
      ORDER BY revenueAtRisk DESC, orderCount DESC
      LIMIT 1
    `;

    const traceQuery = `
      SELECT p.traceId, p.orderId, p.customerId, p.accountId, p.serviceName,
             p.authorizationStatus, p.declineReason, p.latencyMs, p.amount, p.createdTime
      FROM \`${bucketName}\`.\`${scopeName}\`.payments p
      WHERE p.incidentId = $incidentId
      ORDER BY CASE WHEN p.authorizationStatus = "DECLINED" THEN 0 ELSE 1 END,
               p.latencyMs DESC,
               p.createdTime DESC
      LIMIT 1
    `;

    const orderQuery = `
      SELECT o.orderId, o.customerId, o.accountId, o.accountName, o.traceId,
             o.status, o.totalAmount, o.serviceName, o.orderTime
      FROM \`${bucketName}\`.\`${scopeName}\`.orders o
      WHERE o.incidentId = $incidentId
      ORDER BY o.totalAmount DESC, o.orderTime DESC
      LIMIT 1
    `;

    const rootCauseQuery = `
      WITH recent_payments AS (
        SELECT p.serviceName, p.paymentId, p.authorizationStatus, p.latencyMs
        FROM \`${bucketName}\`.\`${scopeName}\`.payments p
        WHERE p.incidentId = $incidentId
        ORDER BY p.createdTime DESC
        LIMIT 1000
      )
      SELECT IFMISSINGORNULL(p.serviceName, "unknown") AS serviceName,
             COUNT(1) AS paymentAttempts,
             SUM(CASE WHEN p.authorizationStatus = "DECLINED" THEN 1 ELSE 0 END) AS failedPayments,
             SUM(CASE WHEN p.latencyMs >= 800 THEN 1 ELSE 0 END) AS slowPayments,
             ROUND(AVG(p.latencyMs), 2) AS avgLatencyMs,
             MAX(p.latencyMs) AS maxLatencyMs
      FROM recent_payments p
      GROUP BY IFMISSINGORNULL(p.serviceName, "unknown")
      ORDER BY failedPayments DESC, slowPayments DESC, avgLatencyMs DESC
      LIMIT 1
    `;

    const [accountRows, customerRows, traceRows, orderRows, rootCauseRows] = await Promise.all([
      runQueryOrEmpty('best records account', accountQuery, params),
      runQueryOrEmpty('best records customer', customerQuery, params),
      runQueryOrEmpty('best records trace', traceQuery, params),
      runQueryOrEmpty('best records order', orderQuery, params),
      runQueryOrEmpty('best records root cause', rootCauseQuery, params)
    ]);

    const account = firstRow(accountRows, null);
    const customer = firstRow(customerRows, null);
    const trace = firstRow(traceRows, null);
    const order = firstRow(orderRows, null);
    const suspectedService = firstRow(rootCauseRows, null);
    const ready = Boolean(incident?.incidentId && account?.accountId && customer?.customerId && (trace?.traceId || order?.traceId));
    const missing = [];
    if (!account?.accountId) missing.push('linked account');
    if (!customer?.customerId) missing.push('linked customer');
    if (!trace?.traceId && !order?.traceId) missing.push('representative trace');

    res.json({
      ready,
      message: ready
        ? 'Demo-ready records found.'
        : `Incident found, but missing ${missing.join(', ') || 'linked business data'}. Generate more scenario traffic if this remains empty.`,
      incident,
      account,
      customer,
      order,
      trace,
      suspectedService,
      recommendedPath: [
        { step: 1, label: 'Open Incident', target: incident.incidentId, tab: 'command' },
        { step: 2, label: 'Show Business Impact', target: account?.accountId || customer?.customerId, tab: 'business' },
        { step: 3, label: 'Show Root Cause', target: suspectedService?.serviceName, tab: 'rootCause' },
        { step: 4, label: 'Show Timeline', target: incident.incidentId, tab: 'timeline' },
        { step: 5, label: 'Open Trace Detail', target: trace?.traceId || order?.traceId, tab: 'trace' }
      ]
    });
  } catch (err) {
    console.error('[API Error] Best demo records error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// 7. Normalized investigation timeline
app.get('/api/timeline', async (req, res) => {
  const filters = {
    incidentId: req.query.incidentId,
    traceId: req.query.traceId,
    orderId: req.query.orderId,
    customerId: req.query.customerId,
    accountId: req.query.accountId
  };

  if (!Object.values(filters).some(Boolean)) {
    return res.status(400).json({ error: 'Provide one of incidentId, traceId, orderId, customerId, or accountId.' });
  }

  const orderFilter = buildTimelinePredicate('o', filters);
  const paymentFilter = buildTimelinePredicate('p', filters);
  const shipmentFilter = buildTimelinePredicate('s', filters);
  const ticketFilter = buildTimelinePredicate('t', filters);
  const deploymentFilter = filters.incidentId
    ? { where: 'd.incidentId = $incidentId', params: { incidentId: filters.incidentId } }
    : { where: null, params: {} };
  const incidentFilter = filters.incidentId
    ? { where: 'i.incidentId = $incidentId', params: { incidentId: filters.incidentId } }
    : { where: null, params: {} };

  try {
    const incidentQuery = incidentFilter.where ? `
      SELECT i.incidentId, i.scenario, i.title, i.severity, i.status, i.startedAt, i.resolvedAt,
             i.ownerTeam, i.affectedServices, i.affectedRegions, i.actualRevenueAtRisk,
             i.affectedOrderCount, i.affectedCustomerCount
      FROM \`${bucketName}\`.\`${scopeName}\`.incidents i
      WHERE ${incidentFilter.where}
      LIMIT 1
    ` : null;

    const deploymentsQuery = deploymentFilter.where ? `
      SELECT d.deploymentId, d.serviceName, d.version, d.status, d.changeRisk, d.deployedBy,
             d.timestamp, d.incidentId
      FROM \`${bucketName}\`.\`${scopeName}\`.deployments d
      WHERE ${deploymentFilter.where}
      ORDER BY d.timestamp DESC
      LIMIT 20
    ` : null;

    const ordersQuery = `
      SELECT o.orderId, o.customerId, o.accountId, o.accountName, o.incidentId, o.traceId,
             o.status, o.totalAmount, o.serviceName, o.region, o.orderTime
      FROM \`${bucketName}\`.\`${scopeName}\`.orders o
      WHERE ${orderFilter.where}
      ORDER BY o.orderTime DESC
      LIMIT 50
    `;

    const paymentsQuery = `
      SELECT p.paymentId, p.orderId, p.customerId, p.accountId, p.incidentId, p.traceId,
             p.authorizationStatus, p.declineReason, p.processor, p.amount, p.latencyMs,
             p.serviceName, p.createdTime
      FROM \`${bucketName}\`.\`${scopeName}\`.payments p
      WHERE ${paymentFilter.where}
      ORDER BY p.createdTime DESC
      LIMIT 50
    `;

    const shipmentsQuery = `
      SELECT s.shipmentId, s.orderId, s.customerId, s.accountId, s.incidentId, s.traceId,
             s.status, s.delayReason, s.carrier, s.fulfillmentCenter, s.serviceName, s.createdTime
      FROM \`${bucketName}\`.\`${scopeName}\`.shipments s
      WHERE ${shipmentFilter.where}
      ORDER BY s.createdTime DESC
      LIMIT 50
    `;

    const ticketsQuery = `
      SELECT t.ticketId, t.customerId, t.accountId, t.orderId, t.incidentId, t.traceId,
             t.issueType, t.status, t.severity, t.sentiment, t.slaBreachRisk, t.serviceName,
             t.createdTime
      FROM \`${bucketName}\`.\`${scopeName}\`.support_tickets t
      WHERE ${ticketFilter.where}
      ORDER BY t.createdTime DESC
      LIMIT 50
    `;

    const [incidentRows, deploymentRows, orders, payments, shipments, tickets] = await Promise.all([
      incidentQuery ? runQueryOrEmpty('timeline incident', incidentQuery, incidentFilter.params) : Promise.resolve([]),
      deploymentsQuery ? runQueryOrEmpty('timeline deployments', deploymentsQuery, deploymentFilter.params) : Promise.resolve([]),
      runQueryOrEmpty('timeline orders', ordersQuery, orderFilter.params),
      runQueryOrEmpty('timeline payments', paymentsQuery, paymentFilter.params),
      runQueryOrEmpty('timeline shipments', shipmentsQuery, shipmentFilter.params),
      runQueryOrEmpty('timeline tickets', ticketsQuery, ticketFilter.params)
    ]);

    const events = [];
    for (const incident of incidentRows) {
      events.push(normalizeTimelineEvent({
        id: `incident-start-${incident.incidentId}`,
        type: 'incident',
        severity: incident.severity || 'INFO',
        timestamp: incident.startedAt,
        title: `${incident.title || incident.incidentId} started`,
        subtitle: `${incident.status || 'UNKNOWN'} - ${incident.ownerTeam || 'Unassigned'}`,
        entityId: incident.incidentId,
        details: incident
      }));
      if (incident.resolvedAt) {
        events.push(normalizeTimelineEvent({
          id: `incident-resolved-${incident.incidentId}`,
          type: 'recovery',
          severity: 'INFO',
          timestamp: incident.resolvedAt,
          title: `${incident.title || incident.incidentId} moved to recovery`,
          subtitle: 'Mitigation or rollback completed',
          entityId: incident.incidentId,
          details: incident
        }));
      }
    }

    for (const deployment of deploymentRows) {
      events.push(normalizeTimelineEvent({
        id: `deployment-${deployment.deploymentId}`,
        type: 'deployment',
        severity: deployment.changeRisk === 'HIGH' ? 'WARN' : 'INFO',
        timestamp: deployment.timestamp,
        title: `${deployment.serviceName} deployed ${deployment.version}`,
        subtitle: `${deployment.status || 'UNKNOWN'} - ${deployment.changeRisk || 'UNKNOWN'} risk`,
        entityId: deployment.deploymentId,
        serviceName: deployment.serviceName,
        details: deployment
      }));
    }

    for (const order of orders) {
      const isProblem = ['PAYMENT_REVIEW', 'INVENTORY_REVIEW', 'ESCALATED', 'DELAYED'].includes(order.status);
      events.push(normalizeTimelineEvent({
        id: `order-${order.orderId}`,
        type: 'order',
        severity: isProblem ? 'WARN' : 'INFO',
        timestamp: order.orderTime,
        title: `Order ${order.orderId} ${order.status || 'CREATED'}`,
        subtitle: `${order.accountName || order.accountId || 'Unknown account'} - $${order.totalAmount || 0}`,
        entityId: order.orderId,
        serviceName: order.serviceName,
        traceId: order.traceId,
        details: order
      }));
    }

    for (const payment of payments) {
      const isDeclined = payment.authorizationStatus === 'DECLINED';
      const isSlow = Number(payment.latencyMs || 0) >= 800;
      events.push(normalizeTimelineEvent({
        id: `payment-${payment.paymentId}`,
        type: 'payment',
        severity: isDeclined ? 'ERROR' : (isSlow ? 'WARN' : 'INFO'),
        timestamp: payment.createdTime,
        title: `Payment ${payment.authorizationStatus || 'UNKNOWN'}`,
        subtitle: `${payment.processor || 'processor'} - ${payment.latencyMs || 0}ms${payment.declineReason ? ` - ${payment.declineReason}` : ''}`,
        entityId: payment.paymentId,
        serviceName: payment.serviceName,
        traceId: payment.traceId,
        details: payment
      }));
    }

    for (const shipment of shipments) {
      const isDelayed = shipment.status === 'DELAYED' || shipment.status === 'PENDING_PAYMENT';
      events.push(normalizeTimelineEvent({
        id: `shipment-${shipment.shipmentId}`,
        type: 'shipment',
        severity: isDelayed ? 'WARN' : 'INFO',
        timestamp: shipment.createdTime,
        title: `Shipment ${shipment.status || 'UNKNOWN'}`,
        subtitle: `${shipment.carrier || 'carrier'} - ${shipment.delayReason || shipment.fulfillmentCenter || 'fulfillment'}`,
        entityId: shipment.shipmentId,
        serviceName: shipment.serviceName,
        traceId: shipment.traceId,
        details: shipment
      }));
    }

    for (const ticket of tickets) {
      events.push(normalizeTimelineEvent({
        id: `ticket-${ticket.ticketId}`,
        type: 'support_ticket',
        severity: ticket.slaBreachRisk ? 'ERROR' : (ticket.severity || 'WARN'),
        timestamp: ticket.createdTime,
        title: `Support ticket opened: ${ticket.issueType || 'Issue'}`,
        subtitle: `${ticket.status || 'OPEN'} - ${ticket.sentiment || 'neutral'} sentiment`,
        entityId: ticket.ticketId,
        serviceName: ticket.serviceName,
        traceId: ticket.traceId,
        details: ticket
      }));
    }

    events.sort((a, b) => (a.timestamp || 0) - (b.timestamp || 0));

    res.json({
      filters,
      count: events.length,
      eventTypes: [...new Set(events.map(event => event.type))],
      events
    });
  } catch (err) {
    console.error('[API Error] Timeline error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// 4. Search Endpoint
app.get('/api/search', async (req, res) => {
  const { query, type } = req.query;
  if (!query) {
    return res.status(400).json({ error: 'Query parameter is required' });
  }

  try {
    let n1ql = '';
    let params = { searchVal: query };
    let results = [];

    if (type === 'traceId') {
      // Find orders matching traceId directly
      n1ql = `SELECT o.orderId, o.customerId, o.traceId, o.totalAmount, o.orderTime, 'order' as docType 
              FROM \`${bucketName}\`.\`${scopeName}\`.orders o 
              WHERE o.traceId = $searchVal
              LIMIT 20`;
      results = await runQuery(n1ql, params);
    } else if (type === 'orderId') {
      n1ql = `SELECT o.orderId, o.customerId, o.traceId, o.totalAmount, o.orderTime, 'order' as docType 
              FROM \`${bucketName}\`.\`${scopeName}\`.orders o 
              WHERE o.orderId = $searchVal
              LIMIT 20`;
      results = await runQuery(n1ql, params);
    } else if (type === 'customerId') {
      n1ql = `SELECT o.orderId, o.customerId, o.traceId, o.totalAmount, o.orderTime, 'order' as docType 
              FROM \`${bucketName}\`.\`${scopeName}\`.orders o 
              WHERE o.customerId = $searchVal
              ORDER BY o.orderTime DESC LIMIT 20`;
      results = await runQuery(n1ql, params);
    } else {
      const [orderRows, customerRows, traceRows] = await Promise.all([
        runQuery(`SELECT o.orderId, o.customerId, o.traceId, o.totalAmount, o.orderTime, 'order' as docType
                  FROM \`${bucketName}\`.\`${scopeName}\`.orders o
                  WHERE o.orderId = $searchVal
                  LIMIT 5`, params),
        runQuery(`SELECT o.orderId, o.customerId, o.traceId, o.totalAmount, o.orderTime, 'order' as docType
                  FROM \`${bucketName}\`.\`${scopeName}\`.orders o
                  WHERE o.customerId = $searchVal
                  ORDER BY o.orderTime DESC
                  LIMIT 10`, params),
        runQuery(`SELECT o.orderId, o.customerId, o.traceId, o.totalAmount, o.orderTime, 'order' as docType
                  FROM \`${bucketName}\`.\`${scopeName}\`.orders o
                  WHERE o.traceId = $searchVal
                  LIMIT 5`, params)
      ]);
      const seen = new Set();
      results = [...orderRows, ...customerRows, ...traceRows].filter(row => {
        const key = row.orderId || `${row.customerId}-${row.traceId}`;
        if (seen.has(key)) return false;
        seen.add(key);
        return true;
      });
    }

    res.json(results);
  } catch (err) {
    console.error('[API Error] Search error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// 2. Correlation Endpoint (Timeline View payload)
app.get('/api/correlation/:traceId', async (req, res) => {
  const { traceId } = req.params;

  try {
    // A. Query Order & Customer details (JOIN)
    const orderN1ql = `
      SELECT o.orderId, o.customerId, o.sessionId, o.totalAmount, o.items, o.orderTime, o.traceId,
             c.name AS customerName, c.email AS customerEmail, c.country AS customerCountry
      FROM \`${bucketName}\`.\`${scopeName}\`.orders o
      LEFT JOIN \`${bucketName}\`.\`${scopeName}\`.customers c ON o.customerId = c.customerId
      WHERE o.traceId = $traceId
    `;
    
    // B. Query Support Tickets
    const ticketN1ql = `
      SELECT t.ticketId, t.issueType, t.status, t.createdTime, t.traceId
      FROM \`${bucketName}\`.\`${scopeName}\`.support_tickets t
      WHERE t.traceId = $traceId
    `;

    // C. Query OpenTelemetry spans from traces collection
    const traceN1ql = `
      SELECT 
          s.name AS spanName, 
          s.spanId, 
          s.parentSpanId,
          DIV(TONUMBER(s.startTimeUnixNano), 1000000) AS startTimeMs, 
          DIV(TONUMBER(s.endTimeUnixNano) - TONUMBER(s.startTimeUnixNano), 1000000) AS durationMs,
          s.attributes
      FROM \`${bucketName}\`.\`${scopeName}\`.traces t
      UNNEST t.resourceSpans AS rs
      UNNEST rs.scopeSpans AS ss
      UNNEST ss.spans AS s
      WHERE s.traceId = $traceId
      ORDER BY s.startTimeUnixNano ASC
    `;

    // D. Query OpenTelemetry logs
    const logN1ql = `
      SELECT 
          lr.severityText AS severity,
          lr.body.stringValue AS logMessage,
          DIV(TONUMBER(lr.timeUnixNano), 1000000) AS timestampMs
      FROM \`${bucketName}\`.\`${scopeName}\`.\`logs\` l
      UNNEST l.resourceLogs AS rl
      UNNEST rl.scopeLogs AS sl
      UNNEST sl.logRecords AS lr
      WHERE ANY x WITHIN l.resourceLogs SATISFIES x.traceId = $traceId END
        AND lr.traceId = $traceId
      ORDER BY lr.timeUnixNano ASC
    `;

    const params = { traceId };

    const [orders, tickets, spans, logs] = await Promise.all([
      runQueryOrEmpty('orders', orderN1ql, params),
      runQueryOrEmpty('tickets', ticketN1ql, params),
      runQueryOrEmpty('spans', traceN1ql, params),
      runQueryOrEmpty('logs', logN1ql, params)
    ]);

    res.json({
      traceId,
      order: orders[0] || null,
      tickets: tickets,
      spans: spans,
      logs: logs
    });

  } catch (err) {
    console.error('[API Error] Correlation error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/operator/queries', (req, res) => {
  res.json({
    bucket: bucketName,
    scope: scopeName,
    queries: operatorQueryCatalog
  });
});

app.get('/api/operator/queries/:queryId', async (req, res) => {
  const catalogEntry = operatorQueryCatalog.find((entry) => entry.id === req.params.queryId);

  if (!catalogEntry) {
    res.status(404).json({ error: 'Unknown operator query.' });
    return;
  }

  const params = {
    incidentId: req.query.incidentId,
    traceId: req.query.traceId,
    accountId: req.query.accountId,
    customerId: req.query.customerId
  };

  try {
    const result = await executeOperatorQuery(req.params.queryId, params);
    res.json({
      id: catalogEntry.id,
      title: catalogEntry.title,
      purpose: catalogEntry.purpose,
      sql: result.sql,
      params,
      rowCount: result.rows.length,
      rows: result.rows
    });
  } catch (err) {
    console.error('[API Error] Operator query error:', err.message);
    res.status(err.statusCode || 500).json({ error: err.message });
  }
});

// Fallback to React static app
app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

app.listen(PORT, () => {
  console.log(`[INFO] Server running on port ${PORT}`);
});
