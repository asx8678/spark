defmodule ImmoWeb.ErrorJSONTest do
  @moduledoc """
  P1-E5.1 — §6.3 RFC 9457 problem+json acceptance for the
  catch-all `ImmoWeb.ErrorJSON` renderer.

  Phoenix invokes this module when an exception/throw bubbles
  out of a JSON-format action. The body is the RFC 9457
  problem+json shape; the content-type is rewritten to
  `application/problem+json` by
  `ImmoWeb.Plugs.ProblemJsonContentType` (which runs in the
  endpoint and inspects every error response).
  """

  use ImmoWeb.ConnCase, async: true

  test "renders 404" do
    body = ImmoWeb.ErrorJSON.render("404.json", %{})
    assert body.status == 404
    assert body.title == "Not Found"
    assert is_binary(body.type)
    assert String.starts_with?(body.type, "https://docs.immo.local/errors/")
    assert body.detail == "request failed"
  end

  test "renders 500" do
    body = ImmoWeb.ErrorJSON.render("500.json", %{})
    assert body.status == 500
    assert body.title == "Internal Server Error"
    assert is_binary(body.type)
  end
end
