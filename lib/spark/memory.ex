defmodule Spark.Memory do
  @moduledoc """
  Memory subsystem façade — Bronze, Silver, and Gold tiers.

  Bronze: raw JSONL event log per session
  Silver: LLM-compacted summary of history
  Gold: curated, persistent knowledge notes

  All tiers honour secret-filtering: payload keys matching
  ~w(api_key secret token password) are redacted before writing.
  """

  alias Spark.Memory.{Bronze, Silver, Gold}

  @secret_keys ~w(api_key secret token password)

  @doc """
  Filters secret keys from a map payload (shallow + one-level nested).
  """
  @spec filter_secrets(map()) :: map()
  def filter_secrets(payload) when is_map(payload) do
    Map.new(payload, fn {k, v} ->
      if to_string(k) in @secret_keys do
        {k, "[REDACTED]"}
      else
        case v do
          nested when is_map(nested) ->
            {k, filter_secrets(nested)}

          _ ->
            {k, v}
        end
      end
    end)
  end

  def filter_secrets(other), do: other

  @doc "Delegates to Bronze.append/2"
  @spec append(String.t(), map()) :: :ok | {:error, term()}
  defdelegate append(session_id, event), to: Bronze, as: :append

  @doc "Delegates to Silver.compact/2"
  @spec compact(String.t(), [map()]) :: {:ok, map()} | {:error, term()}
  defdelegate compact(session_id, history), to: Silver, as: :compact

  @doc "Delegates to Gold.append_gold/1"
  @spec append_gold(String.t()) :: :ok | {:error, term()}
  defdelegate append_gold(note), to: Gold, as: :append_gold

  @doc "Delegates to Gold.read_gold/0"
  @spec read_gold() :: {:ok, String.t()} | {:error, term()}
  defdelegate read_gold, to: Gold

  @doc "Returns the secret keys list (for testing)."
  @spec secret_keys() :: [String.t()]
  def secret_keys, do: @secret_keys
end
