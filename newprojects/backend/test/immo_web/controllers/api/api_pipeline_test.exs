defmodule ImmoWeb.ApiPipelineTest do
  @moduledoc """
  P1-E5.1 — §6.4 end-to-end pipeline AC.

  Exercises the three `/api/v1` pipelines (`api_build`, `api_render`,
  `api_public`) through the real router (not direct plug calls) so
  the pipeline order, plug composition, and route dispatch are all
  verified.

  Each pipeline has a `/api/v1/__smoke/<scope>` route that returns
  the `conn.assigns.api_scope` (or `nil` for public). The test
  asserts the right scope reaches the controller, the right status
  is returned on failure, and the content-type is problem+json on
  error.
  """

  use ImmoWeb.ConnCase, async: false

  @build_token "test-build-token-0000000000000000000000000000"
  @render_token "test-render-token-0000000000000000000000000000"

  setup do
    on_exit(fn ->
      System.delete_env("BUILD_TOKEN")
      System.delete_env("RENDER_TOKEN")
    end)

    :ok
  end

  describe "api_build pipeline" do
    test "valid build token → 200 with :build scope assigned" do
      System.put_env("BUILD_TOKEN", @build_token)
      conn = get(build_conn() |> put_req_header("authorization", "Bearer #{@build_token}"), "/api/v1/__smoke/build")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["scope"] == "build"
      assert body["api"] == "v1"
    end

    test "no token → 401 problem+json" do
      System.put_env("BUILD_TOKEN", @build_token)
      conn = get(build_conn(), "/api/v1/__smoke/build")
      assert conn.status == 401
      assert problem_json?(conn)
    end

    test "render token on build pipeline → 401" do
      System.put_env("BUILD_TOKEN", @build_token)
      System.put_env("RENDER_TOKEN", @render_token)
      conn = get(build_conn() |> put_req_header("authorization", "Bearer #{@render_token}"), "/api/v1/__smoke/build")
      assert conn.status == 401
    end
  end

  describe "api_render pipeline" do
    test "valid render token → 200 with :render scope assigned" do
      System.put_env("RENDER_TOKEN", @render_token)
      conn = get(build_conn() |> put_req_header("authorization", "Bearer #{@render_token}"), "/api/v1/__smoke/render")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["scope"] == "render"
    end

    test "build token on render pipeline → 401" do
      System.put_env("BUILD_TOKEN", @build_token)
      System.put_env("RENDER_TOKEN", @render_token)
      conn = get(build_conn() |> put_req_header("authorization", "Bearer #{@build_token}"), "/api/v1/__smoke/render")
      assert conn.status == 401
    end
  end

  describe "api_public pipeline" do
    test "anonymous → 200 with scope nil" do
      conn = get(build_conn(), "/api/v1/__smoke/public")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["scope"] == nil
    end

    test "ignored bearer token (public pipeline has no auth)" do
      # The public pipeline should not reject on a random token;
      # CORS + rate limit (P1-E5.4) is the only guard.
      System.put_env("BUILD_TOKEN", @build_token)
      conn = get(build_conn() |> put_req_header("authorization", "Bearer anything"), "/api/v1/__smoke/public")
      assert conn.status == 200
    end
  end


  defp problem_json?(conn) do
    case get_resp_header(conn, "content-type") do
      [ct | _] when is_binary(ct) -> String.starts_with?(ct, "application/problem+json")
      _ -> false
    end
  end
end
