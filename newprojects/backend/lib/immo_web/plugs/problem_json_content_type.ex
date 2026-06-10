defmodule ImmoWeb.Plugs.ProblemJsonContentType do
  @moduledoc """
  §6.3 — Content-type override for JSON error responses.

  Phoenix's default for JSON errors is `application/json`. RFC 9457
  problem+json responses MUST use `application/problem+json`. This
  plug runs late in the pipeline (just before the router) and
  rewrites the response content-type for any 4xx/5xx error response
  whose body looks like the problem+json shape we emit from
  `ImmoWeb.ErrorJSON` and `ImmoWeb.FallbackController`.

  Detection: a 4xx/5xx response with content-type starting
  `application/json` is rewritten to `application/problem+json`.
  Successful 2xx/3xx responses pass through untouched. Responses
  with a different content-type (e.g. HTML) also pass through.

  This plug is mounted globally so the §6.3 contract is enforced
  even for errors raised outside the `/api/v1` scope.
  """

  import Plug.Conn

  @problem_json "application/problem+json"

  @spec init(any()) :: any()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), any()) :: Plug.Conn.t()
  def call(conn, _opts) do
    register_before_send(conn, &rewrite_error_content_type/1)
  end

  # Only rewrite 4xx/5xx with a JSON content-type. Phoenix strips
  # parameters from the header value before storing it, so we just
  # match the prefix and rewrite wholesale.
  defp rewrite_error_content_type(%{status: status} = conn) when status >= 400 and status < 600 do
    case get_resp_header(conn, "content-type") do
      [ct | _] when is_binary(ct) ->
        if json_content_type?(ct) do
          conn
          |> delete_resp_header("content-type")
          |> put_resp_header("content-type", @problem_json)
        else
          conn
        end

      _ ->
        conn
    end
  end

  defp rewrite_error_content_type(conn), do: conn

  # Matches "application/json" and "application/json; charset=utf-8"
  # (the typical Phoenix output for JSON-format errors).
  defp json_content_type?("application/json"), do: true
  defp json_content_type?(<<"application/json;", _::binary>>), do: true
  defp json_content_type?(_), do: false
end
