/**
 * Custom Worker entry stub — real routing in P4-E3 (see plan §3.4).
 */
export default {
  async fetch(): Promise<Response> {
    return new Response('Worker stub — see P4-E3', { status: 501 });
  },
};
