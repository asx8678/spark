defmodule ImmoWeb.Api.IndexController do
  @moduledoc """
  §6.4 / §6.3 — smoke-test controller for the `/api/v1` pipelines.

  P1-E5.1 ships the auth + error surface; this controller proves
  the three pipelines (`api_build`, `api_render`, `api_public`)
  accept/reject requests correctly. The real endpoints land in
  P1-E5.2 (build), P1-E5.3 (render), and P1-E5.4 (public).

  Each action returns a tiny JSON envelope that names the
  authenticated scope (or `nil` for the public tier). The test
  suite in `test/immo_web/plugs/bearer_auth_test.exs` exercises
  these three routes end-to-end to verify the AC.
  """

  use ImmoWeb.Api, :controller

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    json(conn, %{
      api: "v1",
      scope: conn.assigns[:api_scope],
      # nil for :api_public (no auth); :build / :render for authed tiers
      status: "ok"
    })
  end
end
