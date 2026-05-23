defmodule Spark.ToolRunner do
  @moduledoc """
  Executes registered tools in isolated supervised tasks.

  Pipeline:
    1. Lookup tool in Spark.ToolRegistry
    2. Validate args against tool schema
    3. Validate tool call against Spark.Policy
    4. Execute via Task.Supervisor.async_nolink(Spark.ToolSupervisor, ...)
    5. Enforce timeout
    6. Truncate oversized output
    7. Publish tool events (tool_started / tool_completed / tool_failed)
    8. Return structured {:ok, result_map} | {:error, reason_map}
  """

  alias Spark.ToolRegistry
  alias Spark.Policy
  alias Spark.EventBus

  @default_timeout_ms 30_000
  @max_output_bytes 20_000

  @doc """
  Runs a tool by name with the given args and context.

  Returns `{:ok, result_map}` or `{:error, reason_map}`.
  """
  @spec run(String.t() | atom(), map(), map()) :: {:ok, map()} | {:error, map()}
  def run(tool_name, args, context) when is_atom(tool_name) do
    run(Atom.to_string(tool_name), args, context)
  end

  def run(tool_name, args, context) when is_binary(tool_name) and is_map(context) do
    # LLM tool_calls may pass args as a JSON string — decode if needed
    args = normalize_args(args)
    timeout = Map.get(context, :timeout_ms, @default_timeout_ms)
    max_output = Map.get(context, :max_output_bytes, @max_output_bytes)

    with {:ok, entry} <- lookup_tool(tool_name),
         :ok <- validate_schema(entry.module, args),
         :ok <- validate_policy(tool_name, context),
         _ <- publish_started(tool_name, context) do
      exec_supervised(entry.module, tool_name, args, context, timeout, max_output)
    else
      {:error, reason} ->
        publish_failed(tool_name, reason, context)
        {:error, format_error(reason)}
    end
  end

  defp normalize_args(args) when is_map(args), do: args
  defp normalize_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end
  defp normalize_args(_), do: %{}

  # --- Steps ---

  defp lookup_tool(tool_name) do
    case ToolRegistry.lookup(tool_name) do
      {:ok, entry} -> {:ok, entry}
      {:error, {:not_found, _}} -> {:error, {:tool_not_found, tool_name}}
    end
  end

  defp validate_schema(tool_mod, args) do
    schema = tool_mod.schema()
    required = Map.get(schema, :required, Map.get(schema, "required", []))

    missing =
      Enum.filter(required, fn key ->
        k = if is_binary(key), do: String.to_atom(key), else: key
        not Map.has_key?(args, k) and not Map.has_key?(args, key)
      end)

    if missing == [] do
      :ok
    else
      {:error, {:schema_validation_failed, missing}}
    end
  end

  defp validate_policy(tool_name, context) do
    Policy.validate_tool_call(tool_name, %{}, context)
  end

  defp exec_supervised(tool_mod, tool_name, args, context, timeout, max_output) do
    task =
      Task.Supervisor.async_nolink(Spark.ToolSupervisor, fn ->
        tool_mod.execute(args, context)
      end)

    result =
      case Task.yield(task, timeout) || Task.shutdown(task, 5000) do
        {:ok, {:ok, result}} ->
          truncated = truncate_output(result, max_output)
          publish_completed(tool_name, truncated, context)
          {:ok, %{tool: tool_name, result: truncated, status: :ok}}

        {:ok, {:error, reason}} ->
          publish_failed(tool_name, reason, context)
          {:error, %{tool: tool_name, reason: reason, status: :error}}

        nil ->
          publish_failed(tool_name, :timeout, context)
          {:error, %{tool: tool_name, reason: :timeout, status: :timeout}}

        {:exit, crash_reason} ->
          publish_failed(tool_name, {:crashed, crash_reason}, context)
          {:error, %{tool: tool_name, reason: {:crashed, crash_reason}, status: :crashed}}
      end

    result
  end

  # --- Output truncation ---

  defp truncate_output(result, max_bytes) when is_map(result) do
    encoded = try do
      :erlang.term_to_binary(result)
    rescue
      _ -> nil
    end

    if encoded && byte_size(encoded) > max_bytes do
      truncate_map_values(result, max_bytes)
    else
      result
    end
  end

  defp truncate_output(result, _max_bytes), do: result

  defp truncate_map_values(map, max_bytes) do
    map
    |> Enum.map(fn {k, v} ->
      truncated = truncate_value(v, max_bytes)
      {k, truncated}
    end)
    |> Map.new()
  end

  defp truncate_value(binary, max_bytes) when is_binary(binary) do
    if byte_size(binary) > max_bytes do
      kept = binary_part(binary, 0, max_bytes)
      kept <> "\n... [truncated #{byte_size(binary) - max_bytes} bytes]"
    else
      binary
    end
  end

  defp truncate_value(v, _max_bytes), do: v

  # --- Event publishing ---

  defp publish_started(tool_name, context) do
    task_id = Map.get(context, :task_id, "")
    session_id = Map.get(context, :session_id, "")

    EventBus.publish_event(:tool_started, %{tool: tool_name}, [
      task_id: task_id,
      session_id: session_id,
      source: :tool_runner
    ])
  end

  defp publish_completed(tool_name, result, context) do
    task_id = Map.get(context, :task_id, "")
    session_id = Map.get(context, :session_id, "")

    EventBus.publish_event(:tool_completed, %{tool: tool_name, result: result}, [
      task_id: task_id,
      session_id: session_id,
      source: :tool_runner
    ])
  end

  defp publish_failed(tool_name, reason, context) do
    task_id = Map.get(context, :task_id, "")
    session_id = Map.get(context, :session_id, "")

    EventBus.publish_event(:tool_failed, %{tool: tool_name, reason: reason}, [
      task_id: task_id,
      session_id: session_id,
      source: :tool_runner
    ])
  end

  # --- Helpers ---

  defp format_error({:tool_not_found, name}), do: %{tool: name, reason: :not_found, status: :not_found}
  defp format_error({:schema_validation_failed, missing}), do: %{reason: {:missing_required, missing}, status: :schema_error}
  defp format_error({:blocked_by_policy, name}), do: %{tool: name, reason: :blocked_by_policy, status: :policy_error}
  defp format_error({:not_in_allowlist, name}), do: %{tool: name, reason: :not_in_allowlist, status: :policy_error}
  defp format_error({:critical_blocked, name}), do: %{tool: name, reason: :critical_blocked, status: :policy_error}
  defp format_error({:high_risk_blocked, name}), do: %{tool: name, reason: :high_risk_blocked, status: :policy_error}
  defp format_error({:missing_task_id, msg}), do: %{reason: {:missing_task_id, msg}, status: :policy_error}
  defp format_error(reason), do: %{reason: reason, status: :error}
end
