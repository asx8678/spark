defmodule Spark.ModelCatalog do
  @moduledoc """
  Catalog of available LLM models per provider.

  Pure data module — no side effects, no GenServer.
  Used by AgentManager and /agent CLI to show available models.
  """

  @providers %{
    "deepseek" => [
      %{
        id: "deepseek-v4-pro",
        name: "DeepSeek V4 Pro",
        provider: "deepseek",
        description: "Best quality, recommended for planning/orchestration"
      },
      %{
        id: "deepseek-v4-flash",
        name: "DeepSeek V4 Flash",
        provider: "deepseek",
        description: "Fast and efficient, good for coding tasks"
      },
      %{
        id: "deepseek-chat",
        name: "DeepSeek Chat (Legacy)",
        provider: "deepseek",
        description: "Legacy model, deprecated 2026-07-24"
      }
    ],
    "wafer" => [
      %{
        id: "glm-5.1",
        name: "GLM 5.1",
        provider: "wafer",
        description: "Wafer AI flagship, strong coding performance"
      },
      %{
        id: "qwen3.5-397b-a17b",
        name: "Qwen 3.5 397B A17B",
        provider: "wafer",
        description: "Qwen 3.5 397B MoE, 17B active params, via Wafer AI"
      }
    ]
  }

  @doc """
  Returns the list of available provider keys.
  ## Examples
      iex> Spark.ModelCatalog.list_providers()
      ["deepseek", "wafer"]
  """
  @spec list_providers() :: [String.t()]
  def list_providers, do: Map.keys(@providers)

  @doc """
  Returns the list of models for a given provider.
  Returns empty list if provider is unknown.
  ## Examples
      iex> Spark.ModelCatalog.models_for_provider("deepseek") |> length()
      3
      iex> Spark.ModelCatalog.models_for_provider("unknown")
      []
  """
  @spec models_for_provider(String.t()) :: [map()]
  def models_for_provider(provider) do
    Map.get(@providers, provider, [])
  end

  @doc """
  Finds a specific model by provider and model ID.
  Returns nil if not found.
  ## Examples
      iex> Spark.ModelCatalog.find_model("deepseek", "deepseek-v4-pro")[:name]
      "DeepSeek V4 Pro"
      iex> Spark.ModelCatalog.find_model("deepseek", "nonexistent")
      nil
  """
  @spec find_model(String.t(), String.t()) :: map() | nil
  def find_model(provider, model_id) do
    provider
    |> models_for_provider()
    |> Enum.find(&(&1.id == model_id))
  end

  @doc """
  Returns the default base URL for a given provider.
  ## Examples
      iex> Spark.ModelCatalog.default_base_url("deepseek")
      "https://api.deepseek.com"
      iex> Spark.ModelCatalog.default_base_url("wafer")
      "https://pass.wafer.ai/v1"
  """
  @spec default_base_url(String.t()) :: String.t()
  def default_base_url("deepseek"), do: "https://api.deepseek.com"
  def default_base_url("wafer"), do: "https://pass.wafer.ai/v1"
  def default_base_url(_), do: "https://api.deepseek.com"
end
