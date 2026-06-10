import type { AstroIntegration } from 'astro';

export const RENDER_MODES = ['static', 'hybrid', 'dynamic'] as const;
export type RenderMode = (typeof RENDER_MODES)[number];

export function resolveRenderMode(raw = process.env.RENDER_MODE ?? 'static'): RenderMode {
  if (!RENDER_MODES.includes(raw as RenderMode)) {
    throw new Error(`Invalid RENDER_MODE "${raw}". Expected one of: ${RENDER_MODES.join(', ')}`);
  }

  return raw as RenderMode;
}

/** @see plan §2.2 — full hybrid route list arrives in P2 */
export function renderModeIntegration(): AstroIntegration {
  return {
    name: 'immo-render-mode',
    hooks: {
      'astro:config:setup'({ updateConfig }) {
        const mode = resolveRenderMode();

        updateConfig({
          output: mode === 'dynamic' ? 'server' : 'static',
        });
      },
      'astro:route:setup'({ route }) {
        const mode = resolveRenderMode();

        if (mode === 'dynamic') {
          route.prerender = false;
        }
      },
    },
  };
}

export const renderMode = resolveRenderMode();
