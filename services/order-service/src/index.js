/**
 * CloudMart Order Service
 * Manages orders: create, read, update status.
 * Emits order events to Amazon SQS and checks product stock.
 *
 * Queue:
 *   - Default: In-memory event log (local dev / Docker Compose)
 *   - Cloud:   Set QUEUE_BACKEND=sqs (requires IRSA)
 */

const express = require('express');
const cors = require('cors');
const morgan = require('morgan');
const { v4: uuidv4 } = require('uuid');
const axios = require('axios');

// X-Ray tracing (graceful no-op outside AWS)
let AWSXRay;
try {
  AWSXRay = require('aws-xray-sdk');
  AWSXRay.config([AWSXRay.plugins.ECSPlugin]);
  AWSXRay.captureHTTPsGlobal(require('https'), true);
  AWSXRay.captureHTTPsGlobal(require('http'), true);
  console.log('[order-service] AWS X-Ray tracing enabled');
} catch (_) {
  console.log('[order-service] AWS X-Ray SDK not available — tracing disabled');
}

const app = express();
const PORT = process.env.PORT || 8002;
const PRODUCT_SERVICE_URL = process.env.PRODUCT_SERVICE_URL || 'http://product-service:8001';

app.use(cors());
app.use(express.json());
app.use(morgan('combined'));

// Strip /api prefix so routes work whether called via ALB (/api/orders) or directly (/orders)
app.use((req, res, next) => {
  if (req.path.startsWith('/api/')) {
    req.url = req.url.replace(/^\/api/, '');
  }
  next();
});

// ---------------------------------------------------------------------------
// In-memory data store
// ---------------------------------------------------------------------------
const orders = new Map();
const eventLog = [];

const seedOrders = [
  {
    id: 'ord-001',
    userId: 'user-001',
    items: [
      { productId: 'prod-001', name: 'Wireless Bluetooth Headphones', quantity: 1, price: 79.99 },
      { productId: 'prod-003', name: 'USB-C Laptop Stand', quantity: 1, price: 49.99 },
    ],
    total: 129.98,
    status: 'delivered',
    shippingAddress: '42 Galle Road, Colombo 03, Sri Lanka',
    createdAt: '2025-02-10T14:30:00Z',
    updatedAt: '2025-02-15T09:00:00Z',
  },
];
seedOrders.forEach((o) => orders.set(o.id, o));

// ---------------------------------------------------------------------------
// SQS client (lazy-initialised once on first use)
// ---------------------------------------------------------------------------
let _sqsClient = null;

function getSQSClient() {
  if (!_sqsClient) {
    const { SQSClient } = require('@aws-sdk/client-sqs');
    _sqsClient = new SQSClient({ region: process.env.AWS_REGION || 'us-east-1' });
  }
  return _sqsClient;
}

// ---------------------------------------------------------------------------
// Message Queue abstraction
// ---------------------------------------------------------------------------
async function publishOrderEvent(event) {
  const backend = (process.env.QUEUE_BACKEND || 'memory').toLowerCase();

  if (backend === 'sqs') {
    const { SendMessageCommand } = require('@aws-sdk/client-sqs');
    const queueUrl = process.env.SQS_QUEUE_URL;
    if (!queueUrl) throw new Error('SQS_QUEUE_URL env var is required when QUEUE_BACKEND=sqs');

    await getSQSClient().send(new SendMessageCommand({
      QueueUrl: queueUrl,
      MessageBody: JSON.stringify(event),
      // Deduplication for FIFO queues
      ...(queueUrl.endsWith('.fifo') && {
        MessageGroupId: event.orderId,
        MessageDeduplicationId: `${event.type}-${event.orderId}-${Date.now()}`,
      }),
    }));
    console.log(`[SQS] Published ${event.type} for order ${event.orderId}`);
  } else {
    console.log(`[EventLog] ${event.type}: order ${event.orderId}`);
    eventLog.push(event);
  }
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

app.get('/health', (req, res) => {
  res.json({ status: 'healthy', service: 'order-service' });
});

app.get('/ready', async (req, res) => {
  try {
    await axios.get(`${PRODUCT_SERVICE_URL}/health`, { timeout: 2000 });
    res.json({ status: 'ready', service: 'order-service' });
  } catch {
    res.json({ status: 'ready', service: 'order-service', note: 'product-service unreachable but order-service is running' });
  }
});

app.get('/orders', (req, res) => {
  let result = Array.from(orders.values());
  if (req.query.userId) {
    result = result.filter((o) => o.userId === req.query.userId);
  }
  result.sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));
  res.json({ orders: result, count: result.length });
});

app.get('/orders/:orderId', (req, res) => {
  const order = orders.get(req.params.orderId);
  if (!order) {
    return res.status(404).json({ error: 'Not Found', message: `Order ${req.params.orderId} not found` });
  }
  res.json(order);
});

app.post('/orders', async (req, res) => {
  try {
    const { userId, items, shippingAddress } = req.body;

    if (!userId || !items || !Array.isArray(items) || items.length === 0) {
      return res.status(400).json({
        error: 'Bad Request',
        message: 'Missing required fields: userId, items (array with at least 1 item)',
      });
    }

    let total = 0;
    const enrichedItems = [];

    for (const item of items) {
      try {
        const stockRes = await axios.get(
          `${PRODUCT_SERVICE_URL}/products/${item.productId}/stock`,
          { timeout: 3000 }
        );
        if (stockRes.data.stock < (item.quantity || 1)) {
          return res.status(409).json({
            error: 'Insufficient Stock',
            message: `Product ${item.productId} has only ${stockRes.data.stock} units available`,
          });
        }

        const productRes = await axios.get(
          `${PRODUCT_SERVICE_URL}/products/${item.productId}`,
          { timeout: 3000 }
        );
        const product = productRes.data;
        const quantity = item.quantity || 1;
        const lineTotal = product.price * quantity;
        total += lineTotal;

        enrichedItems.push({
          productId: item.productId,
          name: product.name,
          quantity,
          price: product.price,
          lineTotal,
        });

        await axios.post(
          `${PRODUCT_SERVICE_URL}/products/${item.productId}/stock/decrement`,
          { quantity },
          { timeout: 3000 }
        );
      } catch (err) {
        if (err.response && err.response.status === 404) {
          return res.status(404).json({ error: 'Not Found', message: `Product ${item.productId} not found` });
        }
        if (err.response && err.response.status === 409) {
          return res.status(409).json({ error: 'Insufficient Stock', message: err.response.data.message });
        }
        throw err;
      }
    }

    const order = {
      id: `ord-${uuidv4().split('-')[0]}`,
      userId,
      items: enrichedItems,
      total: Math.round(total * 100) / 100,
      status: 'pending',
      shippingAddress: shippingAddress || '',
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };

    orders.set(order.id, order);

    await publishOrderEvent({
      type: 'ORDER_CREATED',
      orderId: order.id,
      userId: order.userId,
      total: order.total,
      items: order.items,
      timestamp: order.createdAt,
    });

    console.log(`[Order] Created: ${order.id} — $${order.total} — ${order.items.length} items`);
    res.status(201).json(order);
  } catch (err) {
    console.error('[Order] Error creating order:', err.message);
    res.status(500).json({ error: 'Internal Server Error', message: 'Failed to create order' });
  }
});

app.patch('/orders/:orderId/status', async (req, res) => {
  const order = orders.get(req.params.orderId);
  if (!order) {
    return res.status(404).json({ error: 'Not Found', message: `Order ${req.params.orderId} not found` });
  }

  const { status } = req.body;
  const validStatuses = ['pending', 'confirmed', 'processing', 'shipped', 'delivered', 'cancelled'];
  if (!validStatuses.includes(status)) {
    return res.status(400).json({
      error: 'Bad Request',
      message: `Invalid status. Must be one of: ${validStatuses.join(', ')}`,
    });
  }

  const oldStatus = order.status;
  order.status = status;
  order.updatedAt = new Date().toISOString();

  await publishOrderEvent({
    type: 'ORDER_STATUS_CHANGED',
    orderId: order.id,
    userId: order.userId,
    oldStatus,
    newStatus: status,
    timestamp: order.updatedAt,
  });

  console.log(`[Order] Status updated: ${order.id} → ${status}`);
  res.json(order);
});

app.get('/events', (req, res) => {
  res.json({ events: eventLog, count: eventLog.length });
});

app.use((err, req, res, next) => {
  console.error('[Error]', err.stack);
  res.status(500).json({ error: 'Internal Server Error' });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`[order-service] Running on port ${PORT}`);
  console.log(`[order-service] Product service URL: ${PRODUCT_SERVICE_URL}`);
  console.log(`[order-service] Queue backend: ${process.env.QUEUE_BACKEND || 'memory'}`);
});

module.exports = app;
