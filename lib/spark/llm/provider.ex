defmodule Spark.LLM.Provider do
  @moduledoc """
  Behaviour for LLM provider implementations.

  Every provider must implement `complete/2` for synchronous completions.
  `stream/3` is optional — providers that don't support streaming can omit it.

  ## Response Shape

  `complete/2` returns `{:ok, response}` where response is:

      %{
        id: "chatcmpl-xxx",
        model: "model-name",
        choices: [%{message: %{role: "assistant", content: "...", tool_calls: [...]}}],
        usage: %{prompt_tokens: n, completion_tokens: n, total_tokens: n}
      }

  `stream/3` calls the callback with:
    - `{:chunk, %{delta: %{content: "..."}}}` for each SSE chunk
    - `{:done, full_response}` at stream end
  """

  @type message :: %{role: String.t(), content: String.t()}
  @type response :: %{
          id: String.t(),
          model: String.t(),
          choices: [map()],
          usage: map()
        }

  @callback complete(messages :: [message()], opts :: map()) ::
              {:ok, response()} | {:error, term()}

  @callback stream(messages :: [message()], opts :: map(), callback :: function()) ::
              {:ok, response()} | {:error, term()}

  @optional_callbacks stream: 3

  @doc """
  Checks if a module implements the Provider behaviour.
  """
  @spec implements?(module()) :: boolean()
  def implements?(module) when is_atom(module) do
    with true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :complete, 2) do
      true
    else
      _ -> false
    end
  end

  @doc """
  Checks if a module supports streaming (implements the optional stream/3 callback).
  """
  @spec supports_streaming?(module()) :: boolean()
  def supports_streaming?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :stream, 3)
  end
end
