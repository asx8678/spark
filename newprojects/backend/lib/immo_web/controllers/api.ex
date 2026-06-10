defmodule ImmoWeb.Api do
  @moduledoc """
  Namespace module for the §6.3 `/api/v1` read API.

  Controllers for the build tier (P1-E5.2), render tier (P1-E5.3),
  and public tier (P1-E5.4) live under `ImmoWeb.Api.*` so the
  router's `scope "/api/v1", ImmoWeb.Api, as: :api_v1` resolves
  them by name. P1-E5.1 declares the pipelines + scope; the
  controllers land in P1-E5.2+.

  Sub-namespaces (`Api.Build`, `Api.Render`, `Api.Public`) may be
  added later if controller counts grow. For now one flat namespace
  keeps the router simple.
  """

  defmacro __using__(:controller) do
    quote do
      use Phoenix.Controller, formats: [:json]
      # All /api/v1 actions must produce problem+json (§6.3) on error.
      # The Phoenix endpoint config wires `ImmoWeb.ErrorJSON` as the
      # catch-all error renderer for JSON format (config/config.exs).
    end
  end
end
