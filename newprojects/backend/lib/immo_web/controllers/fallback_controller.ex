defmodule ImmoWeb.FallbackController do
  @moduledoc """
  §6.3 — RFC 9457 problem+json error rendering for `/api/v1`.

  Every error response on the read API conforms to RFC 9457
  (`application/problem+json`). The `type` is a URI (per the RFC,
  identifiers — may be dereferenceable docs in a later phase);
  `title` is a short human-readable summary; `status` is the
  HTTP status code; `detail` is the per-occurrence explanation.

  Plug-callable variants (`unauthorized/1`, `not_found/1`,
  `unprocessable/1`, `too_many_requests/1`) are mounted by the
  pipelines and BearerAuth; controller-callable variants
  (`render_problem/2`) live here for `with`-style fallbacks
  in P1-E5.2 / P1-E5.3 controllers.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn

  @type problem :: %{
          type: String.t(),
          title: String.t(),
          status: integer(),
          detail: String.t()
        }

  @doc """
  Plug-callable 401. Used by `ImmoWeb.Plugs.BearerAuth` and
  any controller that wants to reject an authenticated request
  (e.g. role mismatch once we add staff-tier auth).
  """
  @spec unauthorized(Conn.t()) :: Conn.t()
  def unauthorized(conn), do: render_problem(conn, 401)

  @doc """
  Plug-callable 404. Used when a build/render request references
  a non-existent or unpublished record.
  """
  @spec not_found(Conn.t()) :: Conn.t()
  def not_found(conn), do: render_problem(conn, 404)

  @doc """
  Plug-callable 422. Used for changeset validation failures
  surfaced as problem+json (not the default Phoenix JSON error).
  """
  @spec unprocessable(Conn.t()) :: Conn.t()
  def unprocessable(conn), do: render_problem(conn, 422)

  @doc """
  Plug-callable 429. Mounted by the `:api_public` pipeline when
  Hammer rate-limit triggers (P1-E5.4).
  """
  @spec too_many_requests(Conn.t()) :: Conn.t()
  def too_many_requests(conn), do: render_problem(conn, 429)

  @doc """
  Generic problem+json render. Accepts either an integer status
  (uses the default title for that status) or a `{status, title,
  detail}` tuple for custom errors.

  ## Examples

      iex> render_problem(conn, 404)
      ...problem+json with title "Not Found"...

      iex> render_problem(conn, {422, "Validation Failed", changeset_message})
      ...problem+json with custom title/detail...
  """
  @spec render_problem(Conn.t(), integer() | {integer(), String.t(), String.t()}) :: Conn.t()
  def render_problem(conn, status) when is_integer(status) do
    {status, title, detail} = defaults_for(status)
    do_render(conn, status, title, detail)
  end

  def render_problem(conn, {status, title, detail})
      when is_integer(status) and is_binary(title) and is_binary(detail) do
    do_render(conn, status, title, detail)
  end

  defp do_render(conn, status, title, detail) do
    body = %{
      type: "https://docs.immo.local/errors/#{slug_for(status)}",
      title: title,
      status: status,
      detail: detail
    }

    conn
    |> put_resp_content_type("application/problem+json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  defp defaults_for(401), do: {401, "Unauthorized", "authentication required"}
  defp defaults_for(403), do: {403, "Forbidden", "you do not have access to this resource"}
  defp defaults_for(404), do: {404, "Not Found", "the requested resource does not exist"}
  defp defaults_for(422), do: {422, "Unprocessable Entity", "the request body failed validation"}
  defp defaults_for(429), do: {429, "Too Many Requests", "rate limit exceeded"}
  defp defaults_for(status), do: {status, "Error", "request failed with status #{status}"}

  defp slug_for(401), do: "unauthorized"
  defp slug_for(403), do: "forbidden"
  defp slug_for(404), do: "not-found"
  defp slug_for(422), do: "unprocessable"
  defp slug_for(429), do: "too-many-requests"
  defp slug_for(status), do: "status-#{status}"
end
