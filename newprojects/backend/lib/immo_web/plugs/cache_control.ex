defmodule ImmoWeb.Plugs.CacheControl do
  @moduledoc """
  §6.3 — public-tier Cache-Control defaults wired into the
  pipeline.
  ## Setting the bucket default in `call/2`

  `Plug.Conn` ships a default `cache-control: max-age=0,
  private, must-revalidate` in every fresh conn. Phoenix's
  `json/2` / `send_resp/2` only copy headers that are already
  on the conn, so setting the bucket default directly in
  `call/2` overrides the Plug default. A controller that
  wants a non-default value can call `put_resp_header/3` after
  the plug runs — its value wins because it is applied later
  in the pipeline.

  ## Defaults

  Per the §6.3 row in the P1-E5.4 spec:

    * `:search` — `private, no-store` (search results can leak
      visitor data via referer-stripped caches; never share).
    * `:geo` — `public, s-maxage=60, stale-while-revalidate=600`
      (geo lookups are public-safe and benefit from CDN caching).

  ## Why a plug

  Centralising the convention here means a controller that
  just wants "default for this bucket" doesn't have to copy
  the header value. It also keeps the §6.3 release-gate
  check ("Cache-Control set on every public GET") one
  assertion in the test suite.

  ## Usage

      pipeline :api_public do
        plug :accepts, ["json"]
        plug ImmoWeb.Plugs.Cors
        # The bucket is inferred from the request path.
        plug ImmoWeb.Plugs.CacheControl
      end
  """

  @behaviour Plug

  import Plug.Conn

  @path_bucket %{
    "/api/v1/search" => :search,
    "/api/v1/listings/geo" => :geo,
    # Smoke routes under `__smoke/public/*` exist so the
    # release-gate tests can verify the §6.3 Cache-Control
    # contract through the real pipeline. Map them to the same
    # bucket as the eventual public endpoint so the test
    # exercises the same code path.
    "/api/v1/__smoke/public/search" => :search,
    "/api/v1/__smoke/public/geo" => :geo
  }

  @impl Plug
  def init(opts), do: opts

  # Override the Plug default (`max-age=0, private, must-revalidate`)
  # in `call/2`, but skip if the controller (or any plug upstream
  # of us in the pipeline) has already set a non-default value.
  # Phoenix's `json/2` / `send_resp/2` only copy headers that
  # are already on the conn, so the bucket default propagates
  # to the wire response when nothing else intervened.
  @plug_default "max-age=0, private, must-revalidate"
  @impl Plug
  def call(conn, _opts) do
    case bucket_for_path(conn.request_path) do
      nil ->
        conn

      bucket ->
        case default_for(bucket) do
          nil -> conn
          default -> maybe_set_cache_control(conn, default)
        end
    end
  end

  # Only set the bucket default if no controller (or earlier
  # plug) has set a different value. The Plug default is fine
  # to overwrite — that IS the override we want — but any other
  # value is a deliberate choice and must be left alone.
  defp maybe_set_cache_control(conn, default) do
    case get_resp_header(conn, "cache-control") do
      [value] when value == @plug_default -> put_resp_header(conn, "cache-control", default)
      # Either no header (shouldn't happen — Plug.Conn ships
      # the default in every fresh conn) or an explicit
      # controller value. Either way, don't override.
      _ -> conn
    end
  end

  @spec bucket_for_path(String.t()) :: atom() | nil
  defp bucket_for_path(path) when is_binary(path) do
    Enum.find_value(@path_bucket, fn {prefix, bucket} ->
      if String.starts_with?(path, prefix), do: bucket
    end)
  end

  @spec default_for(atom()) :: String.t() | nil
  defp default_for(bucket) do
    :immo
    |> Application.get_env(:public_cache_control, [])
    |> Keyword.get(bucket)
  end
end
