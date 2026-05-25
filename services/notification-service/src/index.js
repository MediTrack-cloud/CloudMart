/**
 * CloudMart Notification Service
 * Consumes order events from Amazon SQS and sends email via Amazon SES.
 *
 * This service has NO inbound HTTP traffic from other services (only health checks).
 *
 * Queue Backend:
 *   - Default: Polls order-service /events endpoint (local dev)
 *   - Cloud:   Set QUEUE_BACKEND=sqs (requires IRSA with SQS receive + SES send)
 *
 * Email Backend:
 *   - Default: Console logging (local dev)
 *   - Cloud:   Set EMAIL_BACKEND=ses (requires SES verified sender identity)
 */

const express = require('express');
const morgan = require('morgan');
const axios = require('axios');

// X-Ray tracing (graceful no-op outside AWS)
let AWSXRay;
try {
  AWSXRay = require('aws-xray-sdk');
  AWSXRay.config([AWSXRay.plugins.ECSPlugin]);
  console.log('[notification-service] AWS X-Ray tracing enabled');
} catch (_) {
  console.log('[notification-service] AWS X-Ray SDK not available — tracing disabled');
}

const app = express();
const PORT = process.env.PORT || 8004;
const ORDER_SERVICE_URL = process.env.ORDER_SERVICE_URL || 'http://order-service:8002';

const processedEvents = new Set();
const notificationLog = [];

// ---------------------------------------------------------------------------
// SQS client (lazy-initialised)
// ---------------------------------------------------------------------------
let _sqsClient = null;
let _sesClient = null;

function getSQSClient() {
  if (!_sqsClient) {
    const { SQSClient } = require('@aws-sdk/client-sqs');
    _sqsClient = new SQSClient({ region: process.env.AWS_REGION || 'us-east-1' });
  }
  return _sqsClient;
}

function getSESClient() {
  if (!_sesClient) {
    const { SESClient } = require('@aws-sdk/client-ses');
    _sesClient = new SESClient({ region: process.env.AWS_REGION || 'us-east-1' });
  }
  return _sesClient;
}

// ---------------------------------------------------------------------------
// Email sending abstraction
// ---------------------------------------------------------------------------
async function sendEmail(to, subject, body) {
  const backend = (process.env.EMAIL_BACKEND || 'console').toLowerCase();
  const email = { to, subject, body, sentAt: new Date().toISOString() };

  if (backend === 'ses') {
    const { SendEmailCommand } = require('@aws-sdk/client-ses');
    const fromEmail = process.env.FROM_EMAIL;
    if (!fromEmail) throw new Error('FROM_EMAIL env var is required when EMAIL_BACKEND=ses');

    await getSESClient().send(new SendEmailCommand({
      Source: fromEmail,
      Destination: { ToAddresses: [to] },
      Message: {
        Subject: { Data: subject, Charset: 'UTF-8' },
        Body: { Text: { Data: body, Charset: 'UTF-8' } },
      },
    }));
    console.log(`[SES] Email sent to ${to}: ${subject}`);
  } else {
    console.log(`\n${'='.repeat(60)}`);
    console.log(`EMAIL NOTIFICATION`);
    console.log(`${'='.repeat(60)}`);
    console.log(`To:      ${to}`);
    console.log(`Subject: ${subject}`);
    console.log(`Body:\n${body}`);
    console.log(`${'='.repeat(60)}\n`);
  }

  notificationLog.push({ ...email, backend, status: 'sent' });
  return email;
}

// ---------------------------------------------------------------------------
// Event processing
// ---------------------------------------------------------------------------
function formatCurrency(amount) {
  return `$${Number(amount).toFixed(2)}`;
}

async function processOrderEvent(event) {
  const eventKey = `${event.type}-${event.orderId}-${event.timestamp}`;
  if (processedEvents.has(eventKey)) return;
  processedEvents.add(eventKey);

  if (event.type === 'ORDER_CREATED') {
    const itemList = event.items
      .map((i) => `  - ${i.name} x${i.quantity} @ ${formatCurrency(i.price)}`)
      .join('\n');

    const subject = `CloudMart Order Confirmation — ${event.orderId}`;
    const body = [
      `Hello!`,
      ``,
      `Your order ${event.orderId} has been received and is being processed.`,
      ``,
      `Order Summary:`,
      itemList,
      ``,
      `Total: ${formatCurrency(event.total)}`,
      ``,
      `We'll notify you when your order ships.`,
      ``,
      `Thank you for shopping with CloudMart!`,
    ].join('\n');

    const recipientEmail = `${event.userId}@cloudmart.example`;
    await sendEmail(recipientEmail, subject, body);
    console.log(`[Notification] Processed ORDER_CREATED for ${event.orderId} — ${formatCurrency(event.total)}`);

  } else if (event.type === 'ORDER_STATUS_CHANGED') {
    const subject = `CloudMart Order ${event.orderId} — Status Update`;
    const body = [
      `Hello!`,
      ``,
      `Your order ${event.orderId} status has been updated to: ${event.newStatus}`,
      ``,
      `Thank you for shopping with CloudMart!`,
    ].join('\n');

    const recipientEmail = `${event.userId}@cloudmart.example`;
    await sendEmail(recipientEmail, subject, body);
    console.log(`[Notification] Processed ORDER_STATUS_CHANGED for ${event.orderId} → ${event.newStatus}`);
  }
}

// ---------------------------------------------------------------------------
// SQS long-polling (AWS cloud mode)
// ---------------------------------------------------------------------------
async function pollSQS() {
  const { ReceiveMessageCommand, DeleteMessageCommand } = require('@aws-sdk/client-sqs');
  const queueUrl = process.env.SQS_QUEUE_URL;
  if (!queueUrl) {
    console.error('[SQS] SQS_QUEUE_URL not set — skipping poll');
    return;
  }

  try {
    const response = await getSQSClient().send(new ReceiveMessageCommand({
      QueueUrl: queueUrl,
      MaxNumberOfMessages: 10,
      WaitTimeSeconds: 20,        // long polling — reduces cost vs. tight loop
      VisibilityTimeout: 30,
    }));

    for (const msg of response.Messages || []) {
      try {
        const event = JSON.parse(msg.Body);
        await processOrderEvent(event);
        // Delete only after successful processing
        await getSQSClient().send(new DeleteMessageCommand({
          QueueUrl: queueUrl,
          ReceiptHandle: msg.ReceiptHandle,
        }));
      } catch (err) {
        console.error('[SQS] Failed to process message:', err.message);
        // Message will become visible again after VisibilityTimeout
      }
    }
  } catch (err) {
    console.error('[SQS] Poll error:', err.message);
  }
}

// ---------------------------------------------------------------------------
// Order-service event polling (local dev mode)
// ---------------------------------------------------------------------------
let lastEventCount = 0;

async function pollOrderServiceEvents() {
  try {
    const res = await axios.get(`${ORDER_SERVICE_URL}/events`, { timeout: 3000 });
    const events = res.data.events || [];
    if (events.length > lastEventCount) {
      const newEvents = events.slice(lastEventCount);
      for (const event of newEvents) {
        await processOrderEvent(event);
      }
      lastEventCount = events.length;
    }
  } catch {
    // Silently ignore — order-service might not be ready yet
  }
}

// ---------------------------------------------------------------------------
// Polling loop
// ---------------------------------------------------------------------------
const POLL_INTERVAL_MS = parseInt(process.env.POLL_INTERVAL_MS || '5000', 10);

function startPolling() {
  const backend = (process.env.QUEUE_BACKEND || 'memory').toLowerCase();
  console.log(`[Notification] Starting queue polling every ${POLL_INTERVAL_MS}ms (backend: ${backend})`);

  if (backend === 'sqs') {
    // SQS uses long-polling (20s wait) so we loop immediately after each response
    const loop = async () => {
      await pollSQS();
      setTimeout(loop, 1000); // minimal delay between long-poll cycles
    };
    loop();
  } else {
    setInterval(pollOrderServiceEvents, POLL_INTERVAL_MS);
  }
}

// ---------------------------------------------------------------------------
// HTTP routes (health check only)
// ---------------------------------------------------------------------------
app.use(morgan('combined'));

app.get('/health', (req, res) => {
  res.json({ status: 'healthy', service: 'notification-service' });
});

app.get('/ready', (req, res) => {
  res.json({ status: 'ready', service: 'notification-service' });
});

app.get('/notifications', (req, res) => {
  res.json({ notifications: notificationLog, count: notificationLog.length });
});

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------
app.listen(PORT, '0.0.0.0', () => {
  console.log(`[notification-service] Health endpoint on port ${PORT}`);
  console.log(`[notification-service] Queue backend: ${process.env.QUEUE_BACKEND || 'memory'}`);
  console.log(`[notification-service] Email backend: ${process.env.EMAIL_BACKEND || 'console'}`);
  startPolling();
});

module.exports = app;
