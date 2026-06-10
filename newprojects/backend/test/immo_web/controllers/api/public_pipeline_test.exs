defmodule ImmoWeb.Api.PublicPipelineTest do
  @moduledoc """
  P1-E5.4 — §10.1 path 3 + §13 end-to-end AC for the public
  pipeline scaffold (CORS + Hammer rate-limit + Cache-Control).
  """

  use ImmoWeb.ConnCase, async: false

  alias ImmoWeb.Plugs.RateLimit
  alias Plug.Conn


  @allowed_origin "http://localhost:4321"
  @evil_origin "http://evil.example"

  # Per-test rate-limit config: a high limit by default so
  # unrelated tests don't bump into the bucket. Tests that
  # exercise exhaustion set the limit they need via
  # `Application.put_env` (and the setup restores the
  # default after the test).
  @loose_rate_limit {999_999, 60_000}
  @search_exhaustion_limit {3, 60_000}
  @search_under_limit {10, 60_000}

  setup do
    original = Application.get_env(:immo, :public_rate_limits, [])
    original_origins = Application.get_env(:immo, :public_allowed_origins, [])

    # Default every bucket to a very high limit so the
    # CORS / cache-control tests can run without bumping into
    # the search-bucket exhaustion. Tests that exercise
    # exhaustion flip the search bucket via `Application.put_env`
    # before issuing requests.
    Application.put_env(
      :immo,
      :public_rate_limits,
      search: @loose_rate_limit,
      geo: @loose_rate_limit,
      inquiries: @loose_rate_limit
    )

    # Wipe the Hammer ETS table before every test for isolation.
    # The table is created lazily on the first `hit/3` call; its
    # name is the supervising module atom (per Hammer's
    # `Immo.RateLimiter` declaration in lib/immo/rate_limiter.ex).
    if :ets.whereis(Immo.RateLimiter) != :undefined do
      :ets.delete_all_objects(Immo.RateLimiter)
    end

    on_exit(fn ->
      Application.put_env(:immo, :public_rate_limits, original)
      Application.put_env(:immo, :public_allowed_origins, original_origins)
    end)

    :ok
  end

  describe "§10.1 path 3 / §13 — CORS exact-origin allowlist" do
    test "allowlisted origin preflight gets Access-Control-Allow-* headers" do
      conn = preflight(@allowed_origin)
      assert cors_allow_origin(conn) == @allowed_origin
      [methods] = get_resp_header(conn, "access-control-allow-methods")
      assert String.contains?(methods, "GET")
      assert String.contains?(methods, "POST")
      [max_age] = get_resp_header(conn, "access-control-max-age")
      assert max_age == "86400"
    end

    test "non-allowlisted origin preflight gets NO CORS allow headers" do
      conn = preflight(@evil_origin)
      assert cors_allow_origin(conn) == nil
      assert get_resp_header(conn, "access-control-allow-methods") == []
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end

    test "actual request from allowlisted origin gets the allow header" do
      conn = public_get("/api/v1/__smoke/public/search", @allowed_origin)
      assert conn.status == 200
      assert cors_allow_origin(conn) == @allowed_origin
    end

    test "actual request from a non-allowlisted origin gets NO allow header" do
      conn = public_get("/api/v1/__smoke/public/search", @evil_origin)
      assert conn.status == 200
      assert cors_allow_origin(conn) == nil
    end

    test "wildcard in the allowlist raises ArgumentError (defence-in-depth)" do
      Application.put_env(:immo, :public_allowed_origins, ["*"])

      assert_raise ArgumentError, ~r/wildcard/, fn ->
        conn = build_conn(:get, "/api/v1/__smoke/public/search")
        ImmoWeb.Plugs.Cors.call(conn, ImmoWeb.Plugs.Cors.init([]))
      end
    end
  end

  describe "§10.1 path 3 — Hammer per-IP rate limits" do
    test "under the limit → request passes" do
      Application.put_env(
        :immo,
        :public_rate_limits,
        search: @search_under_limit,
        geo: @loose_rate_limit,
        inquiries: @loose_rate_limit
      )

      conn1 = public_get("/api/v1/__smoke/public/search")
      assert conn1.status == 200

      conn2 = public_get("/api/v1/__smoke/public/search")
      assert conn2.status == 200
    end

    test "exceeding the limit → 429 problem+json with Retry-After" do
      Application.put_env(
        :immo,
        :public_rate_limits,
        search: @search_exhaustion_limit,
        geo: @loose_rate_limit,
        inquiries: @loose_rate_limit
      )

      # 3 hits fit the bucket; the 4th is 429.
      for _ <- 1..3 do
        assert public_get("/api/v1/__smoke/public/search").status == 200
      end

      conn4 = public_get("/api/v1/__smoke/public/search")
      assert conn4.status == 429
      assert problem_json?(conn4)

      [retry_after] = get_resp_header(conn4, "retry-after")
      assert retry_after == "60"

      body = Jason.decode!(conn4.resp_body)
      assert body["status"] == 429
      assert body["title"] == "Too Many Requests"
      assert body["retry_after_seconds"] == 60
    end

    test "per-route buckets are independent (search doesn't deplete geo)" do
      Application.put_env(
        :immo,
        :public_rate_limits,
        search: @search_exhaustion_limit,
        geo: @loose_rate_limit,
        inquiries: @loose_rate_limit
      )

      conn = public_get("/api/v1/__smoke/public/geo")
      assert conn.status == 200
    end

    test "unknown bucket → 503 misconfiguration (fail closed, never bypass)" do
      Application.put_env(:immo, :public_rate_limits, search: {3, 60_000})

      conn = build_conn(:get, "/api/v1/anything")
      conn = RateLimit.call(conn, RateLimit.init(bucket: :does_not_exist))

      assert conn.status == 503
      assert problem_json?(conn)
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == 503
      assert body["title"] == "Rate Limit Misconfigured"
    end
  end

  describe "§6.3 — Cache-Control default per bucket" do
    test ":search path gets `private, no-store`" do
      conn = public_get("/api/v1/__smoke/public/search")
      assert conn.status == 200
      [cc] = get_resp_header(conn, "cache-control")
      assert cc == "private, no-store"
    end

    test ":geo path gets `public, s-maxage=60, ...`" do
      conn = public_get("/api/v1/__smoke/public/geo")
      assert conn.status == 200
      [cc] = get_resp_header(conn, "cache-control")
      assert String.starts_with?(cc, "public, s-maxage=60")
    end

    test "unmatched path (e.g. the legacy __smoke/public) gets no Cache-Control default" do
      conn = public_get("/api/v1/__smoke/public")
      assert conn.status == 200
      [cc] = get_resp_header(conn, "cache-control")
      # The plug's default does NOT apply (no bucket matched);
      # the response carries only the Plug default, not our
      # `private, no-store`.
      refute String.contains?(cc, "no-store")
    end

    test "controller-supplied Cache-Control is NOT overwritten by the plug" do
      conn =
        build_conn(:get, "/api/v1/__smoke/public/search")
        |> Conn.put_resp_header("cache-control", "max-age=10")
        |> ImmoWeb.Plugs.CacheControl.call(ImmoWeb.Plugs.CacheControl.init([]))
        |> Conn.send_resp(200, "")

      [cc] = get_resp_header(conn, "cache-control")
      assert cc == "max-age=10"
    end
  end

  ## Helpers

  defp public_get(path, origin \\ @allowed_origin) do
    build_conn(:get, path)
    |> put_req_header("origin", origin)
    |> get(path)
  end

  defp preflight(origin) do
    conn =
      build_conn(:options, "/api/v1/__smoke/public/search")
      |> put_req_header("origin", origin)
      |> put_req_header("access-control-request-method", "GET")
      |> put_req_header("access-control-request-headers", "content-type")

    options(conn, "/api/v1/__smoke/public/search")
  end

  defp cors_allow_origin(conn) do
    case get_resp_header(conn, "access-control-allow-origin") do
      [value | _] -> value
      _ -> nil
    end
  end

  defp problem_json?(conn) do
    case get_resp_header(conn, "content-type") do
      [ct | _] when is_binary(ct) -> String.starts_with?(ct, "application/problem+json")
      _ -> false
    end
  end
end
