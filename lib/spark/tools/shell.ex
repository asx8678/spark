defmodule Spark.Tools.Bash do
  @moduledoc """
  Executes shell commands via System.cmd with timeout enforcement.

  Blocks dangerous commands (rm -rf /, sudo, etc.) and captures
  exit_code, stdout, and stderr. Requires task_id from context.

  Truncates large output based on context[:max_output_bytes].
  """

  @behaviour Spark.Tool

  @max_output_bytes 20_000
  @default_timeout_ms 30_000

  @dangerous_patterns [
    ~r/\brm\s+.*-[rR].*[fF].*\s\/(\s|$)/,
    ~r/\brm\s+.*-[fF].*[rR].*\s\/(\s|$)/,
    ~r/\brm\s+.*--no-preserve-root/,
    ~r/\bsudo\b/,
    ~r/\bmkfs\b/,
    ~r/\bdd\s+if=.*of=\/dev\//,
    ~r/\bchmod\s+-R\s+777\s+\//,
    ~r/\bchown\s+-R\s+.*\s+\//,
    ~r/\bformat\s+[A-Z]:/i,
    ~r/\bshutdown\b/,
    ~r/\breboot\b/,
    ~r/\binit\s+[06]/,
    ~r/\bwget\s+.*\|\s*sh\b/,
    ~r/\bcurl\s+.*\|\s*(ba)?sh\b/
  ]

  @impl true
  def name, do: "bash"

  @impl true
  def description, do: "Execute a shell command with timeout. Blocks dangerous patterns. Requires task_id."

  @impl true
  def schema do
    %{
      type: "object",
      required: ["command", "task_id"],
      properties: %{
        command: %{type: "string", description: "Shell command to execute"},
        task_id: %{type: "string", description: "Owning task identifier"}
      }
    }
  end

  @impl true
  def risk, do: :high

  @impl true
  def execute(%{command: command, task_id: task_id}, context)
      when is_binary(command) and is_binary(task_id) and task_id != "" do
    with :ok <- check_dangerous(command) do
      timeout = Map.get(context, :timeout_ms, Map.get(context, :shell_timeout_ms, @default_timeout_ms))
      max = Map.get(context, :max_output_bytes, @max_output_bytes)

      result = execute_command(command, timeout)

      case result do
        {:ok, exit_code, stdout, stderr} ->
          {:ok, %{
            exit_code: exit_code,
            stdout: maybe_truncate(stdout, max),
            stderr: maybe_truncate(stderr, max),
            stdout_truncated: byte_size(stdout) > max,
            stderr_truncated: byte_size(stderr) > max,
            task_id: task_id
          }}

        {:error, :timeout} ->
          {:error, %{command: command, reason: :timeout, task_id: task_id}}

        {:error, reason} ->
          {:error, %{command: command, reason: reason, task_id: task_id}}
      end
    end
  end

  def execute(%{command: _}, _context) do
    {:error, %{reason: :missing_task_id}}
  end

  def execute(_args, _context) do
    {:error, %{reason: :missing_command}}
  end

  # --- Private ---

  defp check_dangerous(command) do
    if Enum.any?(@dangerous_patterns, &Regex.match?(&1, command)) do
      {:error, %{reason: :dangerous_command_blocked, command: command}}
    else
      :ok
    end
  end

  defp execute_command(command, timeout) do
    try do
      task = Task.async(fn ->
        # Wrap in subshell with stderr redirected to temp file for separate capture
        tmp_stderr = Path.join(System.tmp_dir!(), "spark_stderr_#{:erlang.unique_integer([:positive])}")

        cmd_with_redirect = "(#{command}) 2>\"#{tmp_stderr}\""

        {stdout, exit_code} = System.cmd("sh", ["-c", cmd_with_redirect])

        stderr =
          case File.read(tmp_stderr) do
            {:ok, content} -> content
            {:error, _} -> ""
          end

        File.rm(tmp_stderr)

        {exit_code, stdout, stderr}
      end)

      case Task.yield(task, timeout) || Task.shutdown(task, 5000) do
        {:ok, {exit_code, stdout, stderr}} ->
          {:ok, exit_code, stdout, stderr}

        nil ->
          {:error, :timeout}

        {:exit, reason} ->
          {:error, {:crashed, reason}}
      end
    rescue
      e ->
        {:error, {:execution_error, Exception.message(e)}}
    end
  end

  defp maybe_truncate(content, max_bytes) when byte_size(content) > max_bytes do
    binary_part(content, 0, max_bytes) <>
      "\n... [truncated #{byte_size(content) - max_bytes} bytes]"
  end

  defp maybe_truncate(content, _max_bytes), do: content
end
