defmodule ImmoWeb.FallbackControllerTest do
  @moduledoc """
  P1-E5.1 — §6.3 RFC 9457 problem+json acceptance for the
  FallbackController plug-callable variants.

  Verifies that all four standard error helpers (`unauthorized/1`,
  `not_found/1`, `unprocessable/1`, `too_many_requests/1`) emit
  `application/problem+json` bodies with the right status code
  and the four required RFC 9457 fields (`type`, `title`, `status`,
  `detail`).
  """

  use ImmoWeb.ConnCase, async: true

  alias ImmoWeb.FallbackController

  for {func, expected_status} <- [
        {:unauthorized, 401},
        {:not_found, 404},
        {:unprocessable, 422},
        {:too_many_requests, 429}
      ] do
    test "#{func}/1 emits problem+json with status #{expected_status}" do
      conn = apply(FallbackController, unquote(func), [build_conn()])
      [content_type] = get_resp_header(conn, "content-type")
      assert String.starts_with?(content_type, "application/problem+json")
      assert conn.status == unquote(expected_status)
      assert conn.halted

      body = Jason.decode!(conn.resp_body)
      assert is_binary(body["type"])
      assert String.starts_with?(body["type"], "https://")
      assert is_binary(body["title"])
      assert body["status"] == unquote(expected_status)
      assert is_binary(body["detail"])
    end
  end

  describe "render_problem/2 with custom title + detail" do
    test "accepts a 3-tuple {status, title, detail}" do
      conn =
        build_conn()
        |> FallbackController.render_problem({422, "Validation Failed", "name is required"})

      assert conn.status == 422
      body = Jason.decode!(conn.resp_body)
      assert body["title"] == "Validation Failed"
      assert body["detail"] == "name is required"
    end

    test "accepts an integer status (uses default title/detail)" do
      conn = build_conn() |> FallbackController.render_problem(404)
      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["title"] == "Not Found"
    end
  end
end
