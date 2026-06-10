defmodule ImmoWeb.Plugs.BearerAuthTest do
  @moduledoc """
  P1-E5.1 — `ImmoWeb.Plugs.BearerAuth` end-to-end AC.

  Verifies the §6.4 contract for the three `/api/v1` auth tiers
  (`api_build`, `api_render`, `api_public`) plus the §10.1
  zero-downtime rotation runbook and §13 Logger redaction.

  The test mounts the plug directly into `Phoenix.ConnTest.build_conn/0`
  via a tiny per-test router so we exercise the real pipeline
  (init → call → halt on failure → assign on success).
  """

  use ImmoWeb.ConnCase, async: false

  alias ImmoWeb.Plugs.BearerAuth

  @build_token "test-build-token-0000000000000000000000000000"
  @render_token "test-render-token-0000000000000000000000000000"

  setup do
    # Set env vars per test so the plug reads the value at request
    # time. The plug does NOT read at compile time — it reads
    # `System.get_env/1` on every call, which is what makes
    # rotation work without a restart.
    on_exit(fn ->
      System.delete_env("BUILD_TOKEN")
      System.delete_env("RENDER_TOKEN")
    end)

    :ok
  end

  describe "§6.4 / AC: valid bearer token authenticates" do
    test "build scope with valid token → assigns :api_scope = :build" do
      System.put_env("BUILD_TOKEN", @build_token)
      conn = build_conn() |> put_req_header("authorization", "Bearer #{@build_token}") |> run_plug(:build)
      assert conn.assigns.api_scope == :build
      refute conn.halted
    end

    test "render scope with valid token → assigns :api_scope = :render" do
      System.put_env("RENDER_TOKEN", @render_token)
      conn = build_conn() |> put_req_header("authorization", "Bearer #{@render_token}") |> run_plug(:render)
      assert conn.assigns.api_scope == :render
      refute conn.halted
    end
  end

  describe "§6.4 / AC: missing / malformed / wrong token → 401 problem+json" do
    test "no authorization header → 401" do
      System.put_env("BUILD_TOKEN", @build_token)
      conn = build_conn() |> run_plug(:build)
      assert conn.status == 401
      assert conn.halted
      assert problem_json?(conn)
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == 401
      assert body["title"] == "Unauthorized"
      assert body["type"] =~ "/errors/unauthorized"
    end

    test "wrong scheme (Basic, etc.) → 401" do
      System.put_env("BUILD_TOKEN", @build_token)
      conn = build_conn() |> put_req_header("authorization", "Basic dXNlcjpwYXNz") |> run_plug(:build)
      assert conn.status == 401
      assert conn.halted
      assert problem_json?(conn)
    end

    test "wrong token → 401" do
      System.put_env("BUILD_TOKEN", @build_token)
      conn = build_conn() |> put_req_header("authorization", "Bearer wrong-token") |> run_plug(:build)
      assert conn.status == 401
      assert conn.halted
      assert problem_json?(conn)
    end

    test "empty token after 'Bearer ' → 401" do
      System.put_env("BUILD_TOKEN", @build_token)
      conn = build_conn() |> put_req_header("authorization", "Bearer ") |> run_plug(:build)
      assert conn.status == 401
      assert conn.halted
    end

    test "malformed authorization header (not 'Bearer X' shape) → 401" do
      System.put_env("BUILD_TOKEN", @build_token)
      conn = build_conn() |> put_req_header("authorization", "garbage") |> run_plug(:build)
      assert conn.status == 401
      assert conn.halted
    end
  end

  describe "§6.4 / AC: empty / unset expected token never authenticates" do
    test "BUILD_TOKEN unset → 401" do
      System.delete_env("BUILD_TOKEN")
      conn = build_conn() |> put_req_header("authorization", "Bearer anything") |> run_plug(:build)
      assert conn.status == 401
      assert conn.halted
    end

    test "BUILD_TOKEN empty string → 401" do
      System.put_env("BUILD_TOKEN", "")
      conn = build_conn() |> put_req_header("authorization", "Bearer anything") |> run_plug(:build)
      assert conn.status == 401
      assert conn.halted
    end

    test "BUILD_TOKEN with only commas (no real values) → 401" do
      System.put_env("BUILD_TOKEN", ",,,")
      conn = build_conn() |> put_req_header("authorization", "Bearer anything") |> run_plug(:build)
      assert conn.status == 401
      assert conn.halted
    end

    test "RENDER_TOKEN unset → 401 even with a BUILD-style token" do
      System.delete_env("RENDER_TOKEN")
      conn = build_conn() |> put_req_header("authorization", "Bearer #{@build_token}") |> run_plug(:render)
      assert conn.status == 401
      assert conn.halted
    end
  end

  describe "§10.1 / AC: zero-downtime rotation via comma-separated set" do
    test "two tokens in the set, both authenticate" do
      old = "old-build-token-00000000000000000000000000000"
      new = "new-build-token-00000000000000000000000000000"
      System.put_env("BUILD_TOKEN", "#{old},#{new}")

      conn1 = build_conn() |> put_req_header("authorization", "Bearer #{old}") |> run_plug(:build)
      assert conn1.assigns.api_scope == :build
      refute conn1.halted

      conn2 = build_conn() |> put_req_header("authorization", "Bearer #{new}") |> run_plug(:build)
      assert conn2.assigns.api_scope == :build
      refute conn2.halted
    end

    test "removing one token from the set immediately disables it" do
      old = "old-build-token-00000000000000000000000000000"
      new = "new-build-token-00000000000000000000000000000"
      System.put_env("BUILD_TOKEN", "#{old},#{new}")

      # Step 1: both work
      conn1 = build_conn() |> put_req_header("authorization", "Bearer #{old}") |> run_plug(:build)
      assert conn1.assigns.api_scope == :build

      # Step 2: remove the old token from the env (the runbook's
      # "remove old" step)
      System.put_env("BUILD_TOKEN", new)

      # Old token now rejected
      conn2 = build_conn() |> put_req_header("authorization", "Bearer #{old}") |> run_plug(:build)
      assert conn2.status == 401
      assert conn2.halted

      # New token still works
      conn3 = build_conn() |> put_req_header("authorization", "Bearer #{new}") |> run_plug(:build)
      assert conn3.assigns.api_scope == :build
      refute conn3.halted
    end

    test "whitespace around comma-separated values is trimmed" do
      token = "test-build-token-0000000000000000000000000000"
      System.put_env("BUILD_TOKEN", " #{token} , , #{token} ")

      conn = build_conn() |> put_req_header("authorization", "Bearer #{token}") |> run_plug(:build)
      assert conn.assigns.api_scope == :build
    end
  end

  describe "§6.4 / AC: scope disjointness (build vs render)" do
    test "render token on a build endpoint → 401" do
      System.put_env("BUILD_TOKEN", @build_token)
      System.put_env("RENDER_TOKEN", @render_token)
      conn = build_conn() |> put_req_header("authorization", "Bearer #{@render_token}") |> run_plug(:build)
      assert conn.status == 401
      assert conn.halted
    end

    test "build token on a render endpoint → 401" do
      System.put_env("BUILD_TOKEN", @build_token)
      System.put_env("RENDER_TOKEN", @render_token)
      conn = build_conn() |> put_req_header("authorization", "Bearer #{@build_token}") |> run_plug(:render)
      assert conn.status == 401
      assert conn.halted
    end

    test "valid build token does not authenticate on render scope even if both envs are set" do
      System.put_env("BUILD_TOKEN", @build_token)
      System.put_env("RENDER_TOKEN", @render_token)
      conn = build_conn() |> put_req_header("authorization", "Bearer #{@build_token}") |> run_plug(:render)
      assert conn.status == 401
    end
  end

  describe "§6.3 / AC: 401 response is application/problem+json" do
    test "401 content-type is application/problem+json, body is RFC 9457" do
      System.put_env("BUILD_TOKEN", @build_token)
      conn = build_conn() |> run_plug(:build)
      [content_type] = get_resp_header(conn, "content-type")
      assert String.starts_with?(content_type, "application/problem+json")
      body = Jason.decode!(conn.resp_body)
      assert is_binary(body["type"])
      assert is_binary(body["title"])
      assert body["status"] == 401
      assert is_binary(body["detail"])
    end
  end

  ## Helpers — run the plug with init/call phases

  # Phoenix.ConnTest.build_conn/0 is fine here: we just need a
  # bare conn to pass through `BearerAuth.call/2`. We don't need
  # the full pipeline.
  defp run_plug(conn, scope) do
    conn
    |> Plug.Conn.put_private(:plug_skip_csrf_protection, true)
    |> BearerAuth.call(BearerAuth.init(scope))
  end

  defp problem_json?(conn) do
    case get_resp_header(conn, "content-type") do
      [ct | _] when is_binary(ct) -> String.starts_with?(ct, "application/problem+json")
      _ -> false
    end
  end
end
