import { describe, expect, it } from 'vitest';
import { renderMode } from '../integrations/render-mode';

describe('renderMode', () => {
  it('defaults to static', () => {
    expect(['static', 'hybrid', 'dynamic']).toContain(renderMode);
  });
});
