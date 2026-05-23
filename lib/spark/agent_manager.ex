defmodule Spark.AgentManager do
  @moduledoc """
  Registry of named agents with pinned model/provider assignments.

  Each agent maps to an actor type (:orchestrator, :worker, etc.) and
  pins a specific model from a provider. The CLI /agent command lets
  users switch models at runtime. All changes persist to config.json.

  Default agents:
    - planning  → orchestrator → DeepSeek V4 Pro
    - coding    → worker       → GLM 5.1 (Wafer AI)
  """

  use GenServer

  require Logger

  @default_agents %{
    "planning" => %{
      "actor_type" => "orchestrator",
      "provider" => "deepseek",
      "model" => "deepseek-v4-pro",
      "base_url" => "https://api.deepseek.com"
    },
    "coding" => %{
      "actor_type" => "worker",
      "provider" => "wafer",
      "model" => "glm-5.1",
      "base_url" => "https://pass.wafer.ai/v1"
    }
  }

  # --- Public API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns all agent configs as a map keyed by agent name."
  @spec list_agents() :: map()
  def list_agents, do: GenServer.call(__MODULE__, :list_agents)

  @doc "Returns the config for a specific agent, or nil."
  @spec get_agent(String.t()) :: map() | nil
  def get_agent(agent_key), do: GenServer.call(__MODULE__, {:get_agent, agent_key})

  @doc """
  Pins a model to an agent. Persists to config.json.
  Returns {:ok, agent} or {:error, reason}.
  """
  @spec pin_model(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def pin_model(agent_key, model_id), do: GenServer.call(__MODULE__, {:pin_model, agent_key, model_id})

  @doc """
  Resolves actor type to its agent's full config (model, provider, base_url).
  Returns nil if no agent matches the actor type.
  """
  @spec resolve_for_actor(atom()) :: map() | nil
  def resolve_for_actor(actor_type), do: GenServer.call(__MODULE__, {:resolve_for_actor, actor_type})

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    agents = load_agents()
    Logger.info("AgentManager: initialized with #{map_size(agents)} agents")
    {:ok, agents}
  end

  @impl true
  def handle_call(:list_agents, _from, agents), do: {:reply, agents, agents}

  @impl true
  def handle_call({:get_agent, agent_key}, _from, agents) do
    {:reply, Map.get(agents, agent_key), agents}
  end

  @impl true
  def handle_call({:pin_model, agent_key, model_id}, _from, agents) do
    case Map.get(agents, agent_key) do
      nil ->
        {:reply, {:error, "Unknown agent: #{agent_key}"}, agents}

      agent ->
        model = Spark.ModelCatalog.find_model(agent["provider"], model_id)

        if model == nil do
          {:reply, {:error, "Unknown model: #{model_id} for provider #{agent["provider"]}"}, agents}
        else
          updated_agent = Map.put(agent, "model", model_id)
          updated_agents = Map.put(agents, agent_key, updated_agent)

          case persist_agents(updated_agents) do
            :ok ->
              Logger.info("AgentManager: #{agent_key} pinned to #{model_id}")
              {:reply, {:ok, updated_agent}, updated_agents}

            {:error, reason} ->
              Logger.error("AgentManager: failed to persist #{agent_key} pin: #{inspect(reason)}")
              {:reply, {:error, "Failed to persist config: #{inspect(reason)}"}, agents}
          end
        end
    end
  end

  @impl true
  def handle_call({:resolve_for_actor, actor_type}, _from, agents) do
    actor_str = Atom.to_string(actor_type)

    result =
      Enum.find_value(agents, fn {_key, agent} ->
        if agent["actor_type"] == actor_str, do: agent
      end)

    {:reply, result, agents}
  end

  # --- Private ---

  defp load_agents do
    configured = Spark.Config.get(["agents"], %{})

    # Merge with defaults: configured values win, defaults fill gaps
    Map.merge(@default_agents, configured, fn _key, default, configured ->
      Map.merge(default, configured)
    end)
  end

  defp persist_agents(agents) do
    Spark.Config.put_persistent(["agents"], agents)
  end
end
