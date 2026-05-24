defmodule Spark.Orchestrator.Checkpoint do
  @moduledoc """
  Periodic state checkpointing for the Orchestrator.

  Saves critical orchestrator fields to disk so in-flight state can survive
  crashes. Uses atomic writes (tmp + rename) to prevent corruption.

  Checkpoint files live at `~/.spark/sessions/<session_id>.checkpoint`.
  """

  require Logger

  @stale_threshold_ms 60_000

  @doc """
  Saves critical orchestrator state to disk as a binary term.

  Serializes `{phase, active_plan, completed_results, failed_results, timestamp}`
  using `:erlang.term_to_binary/1` and writes atomically via tmp + rename.
  """
  @spec save(Spark.State.t()) :: :ok | {:error, term()}
  def save(%Spark.State{} = state) do
    timestamp = DateTime.utc_now()

    data =
      {state.phase, state.active_plan, state.completed_results, state.failed_results, timestamp}

    binary = :erlang.term_to_binary(data)

    path = checkpoint_path(state.session_id)
    dir = Path.dirname(path)
    tmp_path = path <> ".tmp"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp_path, binary),
         :ok <- File.rename(tmp_path, path) do
      Logger.debug("Checkpoint saved for session #{state.session_id} at phase #{state.phase}")
      :ok
    else
      {:error, reason} ->
        # Clean up tmp file if rename failed
        File.rm(tmp_path)

        Logger.warning(
          "Checkpoint save failed for session #{state.session_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Restores checkpoint state from disk for the given session.

  Returns:
    - `{:ok, checkpoint_map}` — fresh checkpoint found and deserialized
    - `:no_checkpoint` — no checkpoint file exists
    - `{:error, :stale_checkpoint}` — checkpoint older than 60 seconds
    - `{:error, reason}` — deserialization failure
  """
  @spec restore(String.t()) :: {:ok, map()} | :no_checkpoint | {:error, term()}
  def restore(session_id) when is_binary(session_id) do
    path = checkpoint_path(session_id)

    case File.read(path) do
      {:ok, binary} ->
        case :erlang.binary_to_term(binary) do
          {phase, active_plan, completed_results, failed_results, timestamp} ->
            if stale?(timestamp) do
              {:error, :stale_checkpoint}
            else
              {:ok,
               %{
                 phase: phase,
                 active_plan: active_plan,
                 completed_results: completed_results,
                 failed_results: failed_results,
                 timestamp: timestamp
               }}
            end

          _invalid_format ->
            {:error, :invalid_checkpoint_format}
        end

      {:error, :enoent} ->
        :no_checkpoint

      {:error, reason} ->
        {:error, {:read_error, reason}}
    end
  rescue
    e in ArgumentError ->
      # :erlang.binary_to_term raises ArgumentError on corrupt data
      {:error, {:deserialization_failed, Exception.message(e)}}
  end

  # --- Private ---

  defp checkpoint_path(session_id) do
    Path.join([Spark.Config.home_dir(), "sessions", "#{session_id}.checkpoint"])
  end

  defp stale?(%DateTime{} = timestamp) do
    age_ms = DateTime.diff(DateTime.utc_now(), timestamp, :millisecond)
    age_ms > @stale_threshold_ms
  end

  defp stale?(_), do: true
end
