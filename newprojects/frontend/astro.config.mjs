// @ts-check
import cloudflare from '@astrojs/cloudflare';
import { defineConfig, envField } from 'astro/config';
import { renderModeIntegration } from './src/integrations/render-mode.ts';

// https://astro.build/config
export default defineConfig({
  output: 'static',
  adapter: cloudflare(),
  integrations: [renderModeIntegration()],
  i18n: {
    defaultLocale: 'fr',
    locales: ['fr', 'ar', 'en'],
    routing: {
      prefixDefaultLocale: false,
    },
  },
  security: {
    csp: true,
  },
  env: {
    schema: {
      BUILD_TOKEN: envField.string({ context: 'server', access: 'secret' }),
      PUBLIC_SITE_URL: envField.string({ context: 'client', access: 'public', optional: true }),
      API_BASE_URL: envField.string({ context: 'client', access: 'public', optional: true }),
      MEDIA_BASE_URL: envField.string({ context: 'client', access: 'public', optional: true }),
      RENDER_MODE: envField.string({ context: 'server', access: 'public', optional: true, default: 'static' }),
      HYBRID_SSR_ROUTES: envField.string({ context: 'server', access: 'public', optional: true }),
      THEME: envField.string({ context: 'server', access: 'public', optional: true, default: 'default' }),
      LOCALES: envField.string({ context: 'server', access: 'public', optional: true, default: 'fr,ar,en' }),
    },
  },
});
