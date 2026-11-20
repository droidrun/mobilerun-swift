import { test } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createHelper } from './server.mjs';

async function fixture(t, sdk) {
  const server = createHelper(sdk);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise(resolve => server.close(resolve)));
  return `http://127.0.0.1:${server.address().port}/api/v1/devices/device-a`;
}

// SDK 6.2.1 Device.info is DeviceInfo (DeviceRetrieveResponse); extra fields stay private.
test('discovery exposes only the narrow DTO and disables caching', async t => {
  const calls = [];
  const url = await fixture(t, { devices: { get: async id => {
    calls.push(id);
    return { info: { id: 'device-a', state: 'ready', streamUrl: 'wss://stream.test/a',
      streamToken: 'private-static' }, apiKey: 'private-parent' };
  } } });
  const response = await fetch(url);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(response.headers.get('access-control-allow-origin'), null);
  assert.deepEqual(await response.json(), {
    id: 'device-a', state: 'ready', streamUrl: 'wss://stream.test/a',
  });
  assert.deepEqual(calls, ['device-a']);
});

test('missing discovery fields are null', async t => {
  const url = await fixture(t, { devices: { get: async () => ({}) } });
  assert.deepEqual(await (await fetch(url)).json(), { id: null, state: null, streamUrl: null });
});

test('mint uses the official operation once, no retries, and a narrow DTO', async t => {
  const calls = [];
  const url = await fixture(t, { api: { post: async (...args) => {
    calls.push(args);
    return { key: 'key-a', keyId: 'id-a', expiresAt: '2026-11-19T12:02:00Z',
      apiKey: 'private-parent', streamToken: 'private-static' };
  } } });
  const response = await fetch(`${url}/stream-key`, { method: 'POST' });
  assert.equal(response.status, 201);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.deepEqual(await response.json(), {
    key: 'key-a', keyId: 'id-a', expiresAt: '2026-11-19T12:02:00Z',
  });
  assert.deepEqual(calls, [['/identity/stream-keys', {
    body: { deviceId: 'device-a', ttlSeconds: 120 }, maxRetries: 0,
  }]]);
});

for (const status of [401, 403, 404, 409, 429, 503, undefined]) {
  for (const mint of [false, true]) {
    const route = mint ? 'mint' : 'discovery';
    test(`upstream ${status} on ${route}: generic, no retry`, async t => {
      let calls = 0;
      const fail = async () => {
        calls++;
        throw Object.assign(new Error('private-parent private-static private-key'), { status });
      };
      const url = await fixture(t, { api: { post: fail }, devices: { get: fail } });
      const response = await fetch(url + (mint ? '/stream-key' : ''), { method: mint ? 'POST' : 'GET' });
      assert.equal(response.status, status ?? 502);
      assert.equal(response.headers.get('cache-control'), 'no-store');
      assert.deepEqual(await response.json(), { error: 'upstream_request_failed' });
      assert.equal(calls, 1);
    });
  }
}

test('invalid paths and methods do not invoke upstream', async t => {
  const url = await fixture(t, {});
  const wrongMethod = await fetch(`${url}/stream-key`);
  assert.equal(wrongMethod.status, 405);
  assert.equal(wrongMethod.headers.get('cache-control'), 'no-store');
  const invalid = await fetch(`${url}%2Fother/stream-key`, { method: 'POST' });
  assert.equal(invalid.status, 404);
  assert.equal(invalid.headers.get('cache-control'), 'no-store');
});
