/**
 * Unit tests for order-service.
 * Uses Jest with supertest for HTTP testing.
 * Run: npm test
 */

const request = require('supertest');

// Stub out SQS and product-service HTTP calls before importing app
jest.mock('@aws-sdk/client-sqs', () => ({
  SQSClient: jest.fn(),
  SendMessageCommand: jest.fn(),
}));

jest.mock('axios', () => {
  const mockGet = jest.fn().mockImplementation((url) => {
    if (url.includes('/stock')) {
      return Promise.resolve({ data: { stock: 100, available: true } });
    }
    // Return product data with price for enrichment
    return Promise.resolve({ data: { id: 'prod-001', name: 'Test Product', price: 10.00, stock: 100 } });
  });
  return { get: mockGet, post: jest.fn().mockResolvedValue({ data: { message: 'Stock updated' } }) };
});

// Suppress X-Ray import noise
jest.mock('aws-xray-sdk', () => ({
  config: jest.fn(),
  plugins: { ECSPlugin: {} },
  captureHTTPsGlobal: jest.fn(),
}));

const app = require('../index');

describe('Order Service', () => {
  // Health endpoints
  describe('GET /health', () => {
    it('returns 200 with healthy status', async () => {
      const res = await request(app).get('/health');
      expect(res.status).toBe(200);
      expect(res.body.status).toBe('healthy');
    });
  });

  describe('GET /ready', () => {
    it('returns 200', async () => {
      const res = await request(app).get('/ready');
      expect(res.status).toBe(200);
    });
  });

  // List orders
  describe('GET /orders', () => {
    it('returns orders list', async () => {
      const res = await request(app).get('/orders');
      expect(res.status).toBe(200);
      expect(res.body).toHaveProperty('orders');
      expect(Array.isArray(res.body.orders)).toBe(true);
    });
  });

  // Get specific order
  describe('GET /orders/:id', () => {
    it('returns existing order', async () => {
      const res = await request(app).get('/orders/ord-001');
      expect(res.status).toBe(200);
      expect(res.body.id).toBe('ord-001');
    });

    it('returns 404 for nonexistent order', async () => {
      const res = await request(app).get('/orders/nonexistent-id');
      expect(res.status).toBe(404);
    });
  });

  // Create order
  describe('POST /orders', () => {
    const validOrder = {
      userId: 'user-test',
      items: [{ productId: 'prod-001', quantity: 1, price: 79.99, name: 'Test Product' }],
      shippingAddress: '1 Test St, Colombo',
    };

    it('creates an order and returns 201', async () => {
      const res = await request(app).post('/orders').send(validOrder);
      expect(res.status).toBe(201);
      expect(res.body).toHaveProperty('id');
      expect(res.body.status).toBe('pending');
      expect(res.body.userId).toBe('user-test');
    });

    it('returns 400 when items are missing', async () => {
      const res = await request(app).post('/orders').send({ userId: 'u1', shippingAddress: '1 Test' });
      expect(res.status).toBe(400);
    });

    it('calculates total correctly', async () => {
      const res = await request(app).post('/orders').send({
        ...validOrder,
        items: [
          { productId: 'prod-001', quantity: 2, price: 10.00, name: 'A' },
          { productId: 'prod-002', quantity: 1, price: 5.00, name: 'B' },
        ],
      });
      expect(res.status).toBe(201);
      expect(res.body.total).toBeCloseTo(25.00, 2);
    });
  });

  // Update order status
  describe('PATCH /orders/:id/status', () => {
    it('updates order status', async () => {
      // First create
      const created = await request(app).post('/orders').send({
        userId: 'u1',
        items: [{ productId: 'prod-001', quantity: 1, price: 5.00, name: 'X' }],
        shippingAddress: 'Addr',
      });
      const orderId = created.body.id;

      const res = await request(app)
        .patch(`/orders/${orderId}/status`)
        .send({ status: 'confirmed' });
      expect(res.status).toBe(200);
      expect(res.body.status).toBe('confirmed');
    });

    it('returns 404 for nonexistent order', async () => {
      const res = await request(app)
        .patch('/orders/bad-id/status')
        .send({ status: 'confirmed' });
      expect(res.status).toBe(404);
    });
  });
});
