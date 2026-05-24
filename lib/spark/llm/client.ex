defmodule Spark.LLM.Client do
  @moduledoc """
  Public LLM API for Spark.

  Resolves provider, model, and API key from config and secrets,
  then delegates to the appropriate `Spark.LLM.Provider` implementation.

  Actor types: `:orchestrator`, `:worker`, `:prompt_refiner`, `:prompt_lab`

  Emits events via EventBus for each call:
    - `:llm_call_started`
    - `:llm_call_completed`
    - `:llm_call_failed`
  """

  require Logger

  alias Spark.Types.Event
  alias Spark.EventBus

  @actor_types [:orchestrator, :worker, :prompt_refiner, :prompt_lab]

  @doc """
  Performs a synchronous LLM completion for the given actor type.

  Resolves provider, model, and API key from config, then calls
  the provider's `complete/2`.

  Returns `{:ok, response}` or `{:error, reason}`.
  """
  @spec complete(atom(), [map()], map()) :: {:ok, map()} | {:error, term()}
  def complete(actor_type, messages, opts \\ %{})

  def complete(actor_type, messages, opts) when actor_type in @actor_types do
    Logger.metadata(actor_type: actor_type, session_id: Map.get(opts, :session_id))
    provider_mod = resolve_provider(actor_type)
    provider_opts = resolve_opts(actor_type, opts)

    emit_event(
      :llm_call_started,
      %{
        actor_type: actor_type,
        provider: provider_name(provider_mod),
        model: Map.get(provider_opts, :model)
      },
      opts
    )

    case provider_mod.complete(messages, provider_opts) do
      {:ok, response} ->
        emit_event(
          :llm_call_completed,
          %{
            actor_type: actor_type,
            model: response.model,
            usage: response.usage
          },
          opts
        )

        {:ok, response}

      {:error, reason} ->
        emit_event(
          :llm_call_failed,
          %{
            actor_type: actor_type,
            provider: provider_name(provider_mod),
            error: safe_error(reason)
          },
          opts
        )

        {:error, reason}
    end
  end

  def complete(actor_type, _messages, _opts) do
    {:error, {:invalid_actor_type, actor_type}}
  end

  @doc """
  Performs a streaming LLM completion for the given actor type.

  The callback receives `{:chunk, %{delta: %{content: "..."}}}` for each
  chunk and `{:done, full_response}` at the end.

  Returns `{:ok, response}` or `{:error, reason}`.
  """
  @spec stream(atom(), [map()], map(), function()) :: {:ok, map()} | {:error, term()}
  def stream(actor_type, messages, opts \\ %{}, callback)

  def stream(actor_type, messages, opts, callback)
      when actor_type in @actor_types and is_function(callback, 1) do
    Logger.metadata(actor_type: actor_type, session_id: Map.get(opts, :session_id))
    provider_mod = resolve_provider(actor_type)
    provider_opts = resolve_opts(actor_type, opts)

    if Spark.LLM.Provider.supports_streaming?(provider_mod) do
      emit_event(
        :llm_call_started,
        %{
          actor_type: actor_type,
          provider: provider_name(provider_mod),
          model: Map.get(provider_opts, :model),
          streaming: true
        },
        opts
      )

      case provider_mod.stream(messages, provider_opts, callback) do
        {:ok, response} ->
          emit_event(
            :llm_call_completed,
            %{
              actor_type: actor_type,
              model: response.model,
              usage: response.usage,
              streaming: true
            },
            opts
          )

          {:ok, response}

        {:error, reason} ->
          emit_event(
            :llm_call_failed,
            %{
              actor_type: actor_type,
              provider: provider_name(provider_mod),
              error: safe_error(reason)
            },
            opts
          )

          {:error, reason}
      end
    else
      # Fallback: complete + fake streaming
      case complete(actor_type, messages, opts) do
        {:ok, response} ->
          content = get_in(response, [:choices, Access.at(0), :message, :content]) || ""
          callback.({:chunk, %{delta: %{content: content}}})
          callback.({:done, {:ok, response}})
          {:ok, response}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def stream(actor_type, _messages, _opts, _callback) do
    {:error, {:invalid_actor_type, actor_type}}
  end

  @doc """
  Returns the list of valid actor types.
  """
  @spec actor_types() :: [atom()]
  def actor_types, do: @actor_types

  @doc """
  Resolves the provider module for a given actor type.
  """
  @spec resolve_provider(atom()) :: module()
  def resolve_provider(actor_type) when actor_type in @actor_types do
    provider_name =
      case safe_agent_resolve(actor_type) do
        %{"provider" => provider} -> provider
        _ -> Spark.Config.get([:llm, :"#{actor_type}_provider"], "mock")
      end

    provider_module(provider_name)
  end

  # --- Private ---

  defp resolve_opts(actor_type, extra_opts) do
    # Try AgentManager first (per-agent pinned model)
    # Fall back to flat llm.* config if AgentManager is not running
    {model, base_url, provider} =
      case safe_agent_resolve(actor_type) do
        %{"model" => m, "base_url" => u, "provider" => p} -> {m, u, p}
        _ -> fallback_opts(actor_type)
      end

    # API key: try provider-specific key first, fall back to wafer_api_key
    api_key = resolve_api_key(provider)

    %{
      model: model,
      base_url: base_url,
      api_key: api_key,
      timeout_ms: Spark.Config.get([:dispatcher, :default_task_timeout_ms], 60_000)
    }
    |> Map.merge(extra_opts)
  end

  defp provider_module(provider_name) do
    case to_string(provider_name) do
      "mock" ->
        Spark.LLM.MockProvider

      "wafer" ->
        Spark.LLM.WaferProvider

      "deepseek" ->
        Spark.LLM.WaferProvider

      other ->
        # Try to resolve as module name
        try do
          mod = Module.concat([Spark.LLM, Macro.camelize(other) <> "Provider"])
          if Code.ensure_loaded?(mod), do: mod, else: Spark.LLM.MockProvider
        rescue
          _ -> Spark.LLM.MockProvider
        end
    end
  end

  defp safe_agent_resolve(actor_type) do
    Spark.AgentManager.resolve_for_actor(actor_type)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp fallback_opts(actor_type) do
    model = Spark.Config.get([:llm, :"#{actor_type}_model"], "mock-model")
    base_url = Spark.Config.get([:llm, :base_url], "https://pass.wafer.ai/v1")
    provider = Spark.Config.get([:llm, :"#{actor_type}_provider"], "wafer")
    {model, base_url, provider}
  end

  defp resolve_api_key(provider) when is_binary(provider) do
    key_str = "#{provider}_api_key"

    # Try provider-specific key (as string — Secrets accepts strings),
    # then fall back to wafer_api_key, then empty string.
    # We use string keys because Secrets.get_secret/1 accepts both
    # atoms and strings (via to_string/1), and String.to_existing_atom/1
    # fails for keys that haven't been referenced as atoms yet.
    Spark.Config.Secrets.get_secret(key_str) ||
      Spark.Config.Secrets.get_secret(:wafer_api_key) ||
      ""
  end

  defp resolve_api_key(_), do: Spark.Config.Secrets.get_secret(:wafer_api_key) || ""

  defp provider_name(mod) when is_atom(mod) do
    mod
    |> Atom.to_string()
    |> String.replace("Elixir.Spark.LLM.", "")
    |> String.replace("Provider", "")
    |> String.downcase()
  end

  defp safe_error(reason) when is_binary(reason), do: reason
  defp safe_error(reason), do: inspect(reason)

  defp emit_event(type, payload, opts) do
    session_id = Map.get(opts, :session_id, "")
    plan_id = Map.get(opts, :plan_id)
    task_id = Map.get(opts, :task_id)

    event_opts = [
      source: :llm_client,
      session_id: session_id,
      plan_id: plan_id,
      task_id: task_id
    ]

    event = Event.new(type, payload, event_opts)
    EventBus.publish(event.topic, event)
  end
end
