import type { APIRoute } from 'astro';

/** Worker liveness probe — plan §14. */
export const GET: APIRoute = () =>
  new Response(
    JSON.stringify({
      status: 'ok',
      service: 'immo-frontend',
      phase: 'P0-E2.1',
    }),
    {
      status: 200,
      headers: {
        'content-type': 'application/json',
        'cache-control': 'no-store',
      },
    },
  );
