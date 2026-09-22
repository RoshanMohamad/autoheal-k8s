const request = require('supertest');
const app = require('../src/index');

describe('health and readiness', () => {
  it('GET /healthz returns 200', async () => {
    const res = await request(app).get('/healthz');
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ok');
  });

  it('GET /ready returns 200 once started', async () => {
    const res = await request(app).get('/ready');
    expect(res.status).toBe(200);
  });

  it('GET /startupz returns 200 once started', async () => {
    const res = await request(app).get('/startupz');
    expect(res.status).toBe(200);
  });
});

describe('chaos: unready window', () => {
  it('POST /chaos/unready forces /ready to 503 for the window', async () => {
    const trigger = await request(app).post('/chaos/unready').send({ seconds: 1 });
    expect(trigger.status).toBe(200);

    const duringWindow = await request(app).get('/ready');
    expect(duringWindow.status).toBe(503);

    await new Promise((r) => setTimeout(r, 1100));

    const afterWindow = await request(app).get('/ready');
    expect(afterWindow.status).toBe(200);
  });
});

describe('/work', () => {
  it('burns CPU for the requested duration and returns 200', async () => {
    const res = await request(app).get('/work?durationMs=50');
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('done');
  });
});

describe('/metrics', () => {
  it('exposes Prometheus-formatted metrics', async () => {
    const res = await request(app).get('/metrics');
    expect(res.status).toBe(200);
    expect(res.text).toContain('http_request_duration_seconds');
  });
});
