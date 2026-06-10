defmodule Immo.LoggerRedaction do
  @moduledoc """
  §10.1 / §13 — Logger filter that scrubs bearer tokens from log lines.

  Belt-and-braces defense in depth. The `authorization` request header
  is on the §13 redaction list; this filter ALSO scrubs it from any
  log line that might include it (e.g. a third-party library dumping
  the full request, or a debug-level plug call). Without this filter,
  a single misconfigured `Logger.debug(conn)` would put raw tokens in
  log aggregator storage, in violation of §10.1 / §13.

  The filter is wired in `config/config.exs` (compile-time) but the
  filter *function* itself is referenced by name, so the recompile
  needed to change the filter is the same recompile that picks up
  any other redaction-policy change.

  ## Matching rules

  Three patterns are redacted (replaced with `[REDACTED]`):

    1. The `authorization` header value, with any Bearer scheme:
         `authorization: Bearer <token>` → `authorization: Bearer [REDACTED]`
    2. JSON-like `"authorization": "..."` in body fields:
         `"authorization": "abc123"` → `"authorization": "[REDACTED]"`
    3. Query strings with `?token=...` (defensive — we don't put
       tokens in URLs, but a typo in a future controller might):
         `?token=abc123` → `?token=[REDACTED]`

  ## Why a function module (not a Config string)

  `config :logger, :filter, ...` accepts a `{module, fun}` tuple;
  the fun receives the log event and returns a possibly-modified
  event. Using a named module keeps the regex compiling + testing
  in Elixir-land where the rules are exercised by the test suite.
  """

  @doc """
  Logger filter callback. Returns the (possibly-modified) log event.
  """
  @spec filtering(log_event()) :: log_event()
  def filtering(%{msg: msg} = event) do
    case msg do
      {:string, str} -> put_in(event, [:msg], {:string, scrub(str)})
      {:report, report} -> put_in(event, [:msg], {:report, scrub_report(report)})
      _other -> event
    end
  end

  def filtering(event), do: event

  @type log_event :: map()

  @doc """
  Scrub a string of token-shaped content. Public so the test suite
  can exercise the rules without firing through Logger.
  """
  @spec scrub(String.t()) :: String.t()
  def scrub(str) when is_binary(str) do
    str
    |> scrub_bearer_header()
    |> scrub_bare_header()
    |> scrub_json_field()
    |> scrub_query_string()
  end

  # `authorization: Bearer <token>` → `authorization: Bearer [REDACTED]`
  # Case-insensitive on the header name. Non-greedy token match.
  @bearer_header ~r/(authorization\s*[:=]\s*"?bearer\s+)[^\s&",}]+/i

  defp scrub_bearer_header(str) do
    Regex.replace(@bearer_header, str, "\\1[REDACTED]")
  end

  # `authorization: <token>` (no Bearer scheme). Negative lookahead
  # against the literal "bearer" word so we don't re-match an
  # already-redacted Bearer line.
  @bare_header ~r/(authorization\s*[:=]\s*"?)(?!bearer\s)[^\s&",}][^&",}]*/i

  defp scrub_bare_header(str) do
    Regex.replace(@bare_header, str, "\\1[REDACTED]")
  end

  # JSON body field: `"authorization": "..."` / `"token": "..."`
  @json_field ~r/("(?:authorization|token|x-api-token)"\s*:\s*")[^"]*(")/i

  defp scrub_json_field(str) do
    Regex.replace(@json_field, str, "\\1[REDACTED]\\2")
  end

  # Query string: `?token=...&other=...` (defensive)
  @query_string ~r/([?&](?:token|access_token|api_key)=)[^&"\s]+/i

  defp scrub_query_string(str) do
    Regex.replace(@query_string, str, "\\1[REDACTED]")
  end

  defp scrub_report(%{format: format, args: args} = report) do
    scrubbed_args =
      Enum.map(args, fn
        str when is_binary(str) -> scrub(str)
        list when is_list(list) -> Enum.map(list, &scrub/1)
        other -> other
      end)

    put_in(report, [:args], scrubbed_args)
    |> put_in([:format], scrub_format(format))
  end

  defp scrub_report(other), do: other

  defp scrub_format(format) when is_binary(format), do: scrub(format)
  defp scrub_format(other), do: other
end
