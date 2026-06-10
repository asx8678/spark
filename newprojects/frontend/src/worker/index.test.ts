import { describe, expect, it } from 'vitest';
import worker from './index';

describe('hello-world worker', () => {
  it('responds on /__health', async () => {
    const response = await worker.fetch(new Request('https://example.com/__health'));
    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body).toMatchObject({ status: 'ok', service: 'immo-frontend' });
  });

  it('responds with hello-world on /', async () => {
    const response = await worker.fetch(new Request('https://example.com/'));
    expect(response.status).toBe(200);
    expect(await response.text()).toContain('hello-world');
  });
});
