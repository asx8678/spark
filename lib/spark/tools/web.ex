defmodule Spark.Tools.WebFetch do
  @moduledoc """
  Fetches a URL and extracts title/text via Floki.

  Uses Req.get! with timeout. Truncates large pages
  based on context[:max_output_bytes].
  """

  @behaviour Spark.Tool

  @max_output_bytes 20_000
  @default_timeout_ms 15_000

  @impl true
  def name, do: "web_fetch"

  @impl true
  def description, do: "Fetch a URL and extract its title and text content."

  @impl true
  def schema do
    %{
      type: "object",
      required: ["url"],
      properties: %{
        url: %{type: "string", description: "URL to fetch"}
      }
    }
  end

  @impl true
  def risk, do: :medium

  @impl true
  def execute(%{url: url}, context) when is_binary(url) do
    timeout = Map.get(context, :timeout_ms, Map.get(context, :web_timeout_ms, @default_timeout_ms))
    max = Map.get(context, :max_output_bytes, @max_output_bytes)

    try do
      response = Req.get!(url, receive_timeout: timeout, max_redirects: 5)

      status = response.status
      body = response.body

      # Extract title
      title =
        case Floki.find(body, "title") do
          [{_, _, [text | _]} | _] when is_binary(text) -> text
          [{_, _, texts}] when is_list(texts) -> Floki.text(texts)
          _ -> ""
        end

      # Extract visible text (strip scripts, styles)
      text =
        body
        |> Floki.filter_out("script")
        |> Floki.filter_out("style")
        |> Floki.filter_out("noscript")
        |> Floki.text(sep: " ")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

      truncated = maybe_truncate(text, max)

      {:ok, %{
        url: url,
        status: status,
        title: title,
        text: truncated,
        truncated: byte_size(text) > max
      }}
    rescue
      e ->
        {:error, %{url: url, reason: :fetch_error, message: Exception.message(e)}}
    end
  end

  def execute(_args, _context) do
    {:error, %{reason: :missing_url}}
  end

  defp maybe_truncate(content, max_bytes) when byte_size(content) > max_bytes do
    binary_part(content, 0, max_bytes) <>
      "\n... [truncated #{byte_size(content) - max_bytes} bytes]"
  end

  defp maybe_truncate(content, _max_bytes), do: content
end

defmodule Spark.Tools.WebSearch do
  @moduledoc """
  Placeholder for web search functionality.

  Returns a structured note indicating web search is not yet available.
  This tool serves as a stub that can be replaced with a real implementation
  when a search API is integrated.
  """

  @behaviour Spark.Tool

  @impl true
  def name, do: "web_search"

  @impl true
  def description, do: "Search the web for information. Currently a placeholder — returns a structured note."

  @impl true
  def schema do
    %{
      type: "object",
      required: ["query"],
      properties: %{
        query: %{type: "string", description: "Search query string"}
      }
    }
  end

  @impl true
  def risk, do: :low

  @impl true
  def execute(%{query: query}, _context) when is_binary(query) do
    {:ok, %{
      query: query,
      status: :placeholder,
      note: "Web search is not yet available. Integrate a search API provider to enable real results.",
      suggestion: "Use web_fetch to retrieve specific URLs, or implement a search provider (e.g., SearXNG, Brave, Google)."
    }}
  end

  def execute(_args, _context) do
    {:error, %{reason: :missing_query}}
  end
end
