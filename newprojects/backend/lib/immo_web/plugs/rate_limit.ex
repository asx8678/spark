defmodule ImmoWeb.Plugs.RateLimit do
  @moduledoc """
  §10.1 path 3 — Hammer-backed per-IP rate limit for the public
  pipeline (browser islands).

  ## Why a plug

  Hammer's `Hammer.Plug` is gone in v7 (see the v7 upgrade
  notes). The current contract is "do it in a Phoenix controller
  or a plug you write yourself." The plug keeps the call site
  one line in the pipeline (rather than per-action) and lets
  the public endpoints stay free of rate-limit plumbing.

  ## Per-route buckets

  The caller passes a `bucket:` atom at pipeline mount time
  (`:search`, `:geo`, `:inquiries` per §10.1). Each bucket is
  configured independently under
  `:immo, :public_rate_limits` as `{limit, scale_ms}`. Buckets
  are independent: an IP burning through its search budget
  still has its full geo budget.

  ## Source-IP selection

  Cloudflare terminates TLS at the edge and forwards the
  original client IP via the Tunnel peer. The plug reads
  `conn.remote_ip`, which `Plug.RewriteOn` (mounted on the
  endpoint in front of the pipeline) populates from the
  Cloudflare IP allowlist. In dev (loopback), `conn.remote_ip`
  is `127.0.0.1` — fine for both manual testing and tests.

  ## 429 response

  On bucket exhaustion, halt with `429 Too Many Requests` +
  RFC 9457 problem+json. The `Retry-After` header is set to
  the bucket's `scale_ms / 1000` so a polite client backs off
  for one full window.

  ## Unknown bucket fails closed

  A plug mounted with a `bucket:` not in the config returns
  `503` (the misconfiguration must be loud; a 200 here would
  be a rate-limit-bypass in disguise). The test suite catches
  this with an explicit assertion.

  ## Usage

      pipeline :api_public do
        plug :accepts, ["json"]
        plug ImmoWeb.Plugs.Cors
        # /search and /listings/geo get different bucket names —
        # see the controller that mounts the route.
      end
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts) do
    bucket =
      case Keyword.fetch!(opts, :bucket) do
        b when is_atom(b) -> b
        other -> raise ArgumentError, ":bucket must be an atom, got: #{inspect(other)}"
      end

    %{bucket: bucket}
  end

  @impl Plug
  def call(conn, %{bucket: bucket}) do
    case Immo.RateLimiter.bucket_config(bucket) do
      {limit, scale} ->
        key = {bucket, source_ip(conn)}

        case hit_bucket(key, scale, limit) do
          :allow ->
            conn

          {:deny, retry_after_ms} ->
            too_many(conn, bucket, scale, retry_after_ms)
        end

      nil ->
        # Misconfiguration. Don't return 200 — that would be a
        # rate-limit bypass in disguise. 503 surfaces the
        # problem to monitoring (§14 alert).
        misconfigured(conn, bucket)
    end
  end

  ## Implementation

  # The IP address is the shard key. `conn.remote_ip` is
  # populated by `Plug.RewriteOn` (mounted on the endpoint
  # in front of the pipeline) when the request comes through
  # a Cloudflare Tunnel; in dev/tests it is `127.0.0.1`.
  @spec source_ip(Plug.Conn.t()) :: String.t()
  defp source_ip(conn) do
    case conn.remote_ip do
      {_, _, _, _} = ip -> :inet.ntoa(ip) |> to_string()
      {_, _, _, _, _, _, _, _} = ip -> :inet.ntoa(ip) |> to_string()
      _ -> "unknown"
    end
  end

  # Hit the bucket. Hammer 7 returns `{:allow, count}` when
  # the hit was permitted and `{:deny, retry_after_ms}` when
  # the bucket is full. We translate the latter to `{:deny,
  # ms}` so the caller knows how long to set `Retry-After`.
  @spec hit_bucket({atom(), String.t()}, pos_integer(), pos_integer()) ::
          :allow | {:deny, non_neg_integer()}
  defp hit_bucket(key, scale, limit) do
    case Immo.RateLimiter.hit(key, scale, limit) do
      {:allow, _count} -> :allow
      {:deny, retry_after_ms} -> {:deny, retry_after_ms}
    end
  end

  ## Error responses

  @spec too_many(Plug.Conn.t(), atom(), pos_integer(), non_neg_integer()) ::
          Plug.Conn.t()
  defp too_many(conn, bucket, scale_ms, _retry_after_ms) do
    retry_after_seconds = div(scale_ms, 1000)

    conn
    |> put_resp_content_type("application/problem+json")
    |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
    |> send_resp(
      429,
      Jason.encode!(%{
        type: "https://docs.immo.local/errors/too-many-requests",
        title: "Too Many Requests",
        status: 429,
        detail: "rate limit exceeded for bucket #{inspect(bucket)}",
        # Machine-readable hint: how many seconds to wait.
        retry_after_seconds: retry_after_seconds
      })
    )
    |> halt()
  end

  @spec misconfigured(Plug.Conn.t(), atom()) :: Plug.Conn.t()
  defp misconfigured(conn, bucket) do
    conn
    |> put_resp_content_type("application/problem+json")
    |> send_resp(
      503,
      Jason.encode!(%{
        type: "https://docs.immo.local/errors/rate-limit-misconfigured",
        title: "Rate Limit Misconfigured",
        status: 503,
        detail: "no rate-limit config for bucket #{inspect(bucket)}"
      })
    )
    |> halt()
  end
end
