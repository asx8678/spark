defmodule Spark.Tool do
  @moduledoc """
  Behaviour definition for Spark tools.

  Every tool must implement:
    - `name/0` — unique tool identifier (string)
    - `description/0` — human-readable description for LLM consumers
    - `schema/0` — JSON-schema-ish map describing expected args
    - `risk/0` — risk classification (:low | :medium | :high | :critical)
    - `execute/2` — the actual tool logic, returning {:ok, map} | {:error, map}
  """

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback schema() :: map()
  @callback risk() :: :low | :medium | :high | :critical
  @callback execute(args :: map(), context :: map()) :: {:ok, map()} | {:error, map()}

  @doc """
  Checks whether `module` implements all required callbacks of `Spark.Tool`.

  Returns `true` if the module is loaded and defines all five callbacks,
  `false` otherwise.
  """
  @spec implements?(module()) :: boolean()
  def implements?(module) when is_atom(module) do
    callbacks = [
      {:name, 0},
      {:description, 0},
      {:schema, 0},
      {:risk, 0},
      {:execute, 2}
    ]

    try do
      Code.ensure_loaded(module)

      Enum.all?(callbacks, fn {name, arity} ->
        function_exported?(module, name, arity)
      end)
    rescue
      _ -> false
    end
  end
end
