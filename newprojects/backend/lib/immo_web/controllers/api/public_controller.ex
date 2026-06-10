defmodule ImmoWeb.Api.PublicController do
  @moduledoc """
  §10.1 path 3 / P1-E5.4 — public-tier smoke-test controller.

  The real public endpoints (`/search`, `/listings/geo`,
  `POST /inquiries`) land in P5-E1 and P1-E6.1. This
  controller serves the smoke routes that exercise the
  `api_public` pipeline surface end-to-end:

    * `:search` → `/api/v1/__smoke/public/search`
    * `:geo` → `/api/v1/__smoke/public/geo`
    * `:inquiries` → `/api/v1/__smoke/public/inquiries`

  The §6.3 release-gate tests (CORS preflight, 429 on bucket
  exhaustion, Cache-Control per bucket) target these routes
  through the real pipeline. The controller is intentionally
  tiny — its job is to prove the pipeline mounted, not to
  implement the eventual business logic.
  """

  use ImmoWeb.Api, :controller

  @spec search(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def search(conn, _params) do
    json(conn, %{api: "v1", tier: "public", endpoint: "search", status: "ok"})
  end

  @spec geo(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def geo(conn, _params) do
    json(conn, %{api: "v1", tier: "public", endpoint: "geo", status: "ok"})
  end

  @spec inquiries(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def inquiries(conn, _params) do
    json(conn, %{api: "v1", tier: "public", endpoint: "inquiries", status: "ok"})
  end
end
