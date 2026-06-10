defmodule ImmoWeb.ErrorJSON do
  @moduledoc """
  §6.3 — RFC 9457 problem+json error renderer.

  Phoenix calls this module when an exception/throw bubbles out of
  a JSON-format action. We render it as `application/problem+json`
  so even unhandled errors on `/api/v1/*` conform to the API error
  contract.

  Status is extracted from the Phoenix status template
  (e.g. `"404.json"` → 404). The rendered body uses the
  problem+json shape: `type` is a stable URI identifying the
  error class, `title` is the standard HTTP reason phrase,
  `status` is the numeric code, `detail` is the per-occurrence
  explanation.
  """

  # If you want to customize a particular status code,
  # you may add your own clauses, such as:
  #
  # def render("500.json", _assigns) do
  #   %{type: "...", title: "Internal Server Error", status: 500,
  #     detail: "something went wrong"}
  # end

  @doc """
  Phoenix error renderer. Returns the body map; the controller
  layer sets the content-type to `application/problem+json` and
  the response status to the integer from the template.
  """
  def render(template, _assigns) do
    status = status_from_template(template)

    %{
      type: "https://docs.immo.local/errors/#{slug_for(status)}",
      title: Phoenix.Controller.status_message_from_template(template),
      status: status,
      detail: "request failed"
    }
  end

  # "404.json" → 404
  defp status_from_template(template) do
    template
    |> String.split(".")
    |> List.first()
    |> String.to_integer()
  end

  defp slug_for(401), do: "unauthorized"
  defp slug_for(403), do: "forbidden"
  defp slug_for(404), do: "not-found"
  defp slug_for(422), do: "unprocessable"
  defp slug_for(429), do: "too-many-requests"
  defp slug_for(status), do: "status-#{status}"
end
