/**
 * Custom Worker entry — P0-E2.1 hello-world; full freshness routing in P4-E3 (plan §3.4).
 */
export default {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === '/__health') {
      return new Response(
        JSON.stringify({
          status: 'ok',
          service: 'immo-frontend',
          phase: 'P0-E2.1',
          worker: 'custom-entry',
        }),
        {
          status: 200,
          headers: {
            'content-type': 'application/json',
            'cache-control': 'no-store',
          },
        },
      );
    }

    return new Response('Immo Platform — hello-world (P0-E2.1 Worker)', {
      status: 200,
      headers: {
        'content-type': 'text/plain; charset=utf-8',
        'cache-control': 'no-store',
      },
    });
  },
} satisfies ExportedHandler;
