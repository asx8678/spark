defmodule Immo.RateLimiter do
  @moduledoc """
  §10.1 path 3 — Hammer-backed rate limiter for the public
  pipeline (browser islands).

  ## Why a thin module instead of `use Hammer, backend: :ets`
  directly in the plug?

  The plug would otherwise `use Hammer` itself, which would start
  its own GenServer. The plug pipeline runs inside the request
  process, which is the wrong lifecycle for a singleton (and
  mixing `start_link` in a plug call is a footgun). Centralizing
  the limiter in a single supervised process keeps a single ETS
  table for the whole app, exposes a synchronous `hit/3` API, and
  gives us one obvious place to swap backends (Redis for the
  multi-node future) without touching the plug.

  ## Bucket shape

  Keys are constructed as `{bucket_name, ip}` so the same client
  IP can have independent buckets per public endpoint
  (search / geo / inquiries). The plug supplies `bucket_name`
  and derives the IP — see `ImmoWeb.Plugs.RateLimit`.

  ## Scale / limit

  Both are read from the application env at request time:

      config :immo, :public_rate_limits,
        search:   {60, 60_000},   # 60 hits per 60_000 ms (1 min)
        geo:      {120, 60_000},  # 120 hits per min
        inquiries: {5, 60_000},   # 5 hits per min

  These match the §10.1 spec exactly. Callers must pass a
  `bucket_name` that exists in the config map; unknown buckets
  fail closed (return `:ok, 0`) — a missing config is never a
  reason to disable rate limiting.
  """

  use Hammer, backend: :ets

  @doc """
  Read a bucket's `(limit, scale_ms)` tuple from
  `:immo, :public_rate_limits`. Returns `nil` for unknown
  buckets — the plug fails closed on `nil`.
  """
  @spec bucket_config(atom()) :: {pos_integer(), pos_integer()} | nil
  def bucket_config(bucket) when is_atom(bucket) do
    :immo
    |> Application.get_env(:public_rate_limits, [])
    |> Keyword.get(bucket)
  end
end
