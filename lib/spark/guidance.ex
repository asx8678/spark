defmodule Spark.Guidance do
  @moduledoc """
  Guidance system for injecting contextual hints into Worker tool results.

  Loads markdown rule files from `~/.spark/guidance/*.md`, each defining
  a trigger condition and injection message. When a Worker processes a
  tool result, `select/2` matches the result context against loaded
  rules and returns an injection message (or nil).

  Supported rule types (parsed from filenames):
    - `after_edit_failure` — after a file edit tool returns an error
    - `after_grep` — after grep/search tool completes
    - `after_shell_failure` — after a shell command fails
    - `after_large_truncation` — after output is truncated for size

  Hot-reloadable: subscribes to `spark:hot_reload` events and
  reloads guidance files from disk.
  """

  use GenServer

  alias Spark.EventBus
  alias Spark.Config

  @guidance_subdir "guidance"

  @type rule :: %{
          name: atom(),
          trigger: atom(),
          message: String.t(),
          priority: non_neg_integer()
        }

  @type state :: %{
          rules: [rule()],
          version_hash: String.t(),
          files: %{String.t() => rule()}
        }

  # --- Public API ---

  @doc """
  Starts the Guidance GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Loads all guidance files from `~/.spark/guidance/*.md`.

  Returns `{:ok, {rules, version_hash}}` or `{:error, reason}`.
  Can be called directly (for initial load) or via the GenServer.
  """
  @spec load_all() :: {:ok, {[rule()], String.t()}} | {:error, term()}
  def load_all do
    guidance_dir = guidance_dir()

    if File.dir?(guidance_dir) do
      files = Path.wildcard(Path.join(guidance_dir, "*.md"))

      {ok_rules, error_count} =
        files
        |> Enum.map(&parse_guidance_file/1)
        |> Enum.reduce({[], 0}, fn
          {:ok, rule}, {rules, errs} -> {[rule | rules], errs}
          {:error, _reason}, {rules, errs} -> {rules, errs + 1}
        end)

      rules = Enum.reverse(ok_rules)
      version = compute_version(files)

      # Return error if all files failed to parse
      if error_count > 0 and rules == [] do
        {:error, :all_files_invalid}
      else
        {:ok, {rules, version}}
      end
    else
      {:ok, {[], "empty"}}
    end
  end

  @doc """
  Selects a guidance rule matching the tool result and context.

  Returns the injection message string or `nil` if no rule matches.

  `tool_result` is the result from ToolRunner (e.g., `{:error, _}`, `{:ok, _}`).
  `context` is a map with at least `:tool` (atom/string) and optionally
  `:truncated`, `:error`, etc.
  """
  @spec select(term(), map()) :: String.t() | nil
  def select(tool_result, context) when is_map(context) do
    GenServer.call(__MODULE__, {:select, tool_result, context})
  end

  @doc """
  Reloads guidance files from disk.
  """
  @spec reload() :: {:ok, [rule()]} | {:error, term()}
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc """
  Returns the current version hash of loaded guidance files.
  """
  @spec version() :: String.t()
  def version do
    GenServer.call(__MODULE__, :version)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    # Subscribe to hot reload events
    try do
      EventBus.subscribe("spark:hot_reload")
    rescue
      _ -> :ok
    end

    case load_all() do
      {:ok, {rules, version_hash}} ->
        files_map = build_files_map(rules)
        {:ok, %{rules: rules, version_hash: version_hash, files: files_map}}

      {:error, _reason} ->
        # Start with empty state on error — don't crash
        {:ok, %{rules: [], version_hash: "error", files: %{}}}
    end
  end

  @impl true
  def handle_call({:select, tool_result, context}, _from, state) do
    message = match_rule(state.rules, tool_result, context)
    {:reply, message, state}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    case load_all() do
      {:ok, {rules, version_hash}} ->
        files_map = build_files_map(rules)
        {:reply, {:ok, rules}, %{rules: rules, version_hash: version_hash, files: files_map}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:version, _from, state) do
    {:reply, state.version_hash, state}
  end

  # Hot reload event — reload guidance files
  @impl true
  def handle_info(%Spark.Types.Event{type: :guidance_reloaded}, state) do
    case load_all() do
      {:ok, {rules, version_hash}} ->
        files_map = build_files_map(rules)
        {:noreply, %{rules: rules, version_hash: version_hash, files: files_map}}

      {:error, _} ->
        {:noreply, state}
    end
  end

  # Also handle generic hot reload events that might include guidance changes
  @impl true
  def handle_info(%Spark.Types.Event{type: type} = event, state)
      when type in [:config_reloaded, :prompt_reloaded, :tool_reloaded] do
    # Only reload if the event payload mentions guidance
    if Map.get(event.payload, :component) == :guidance or
         Map.get(event.payload, :type) == :guidance do
      case load_all() do
        {:ok, {rules, version_hash}} ->
          files_map = build_files_map(rules)
          {:noreply, %{rules: rules, version_hash: version_hash, files: files_map}}

        {:error, _} ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private: Rule matching ---

  defp match_rule(rules, tool_result, context) do
    trigger = infer_trigger(tool_result, context)

    rules
    |> Enum.filter(fn rule -> rule.trigger == trigger end)
    |> Enum.sort_by(& &1.priority, :desc)
    |> List.first()
    |> case do
      nil -> nil
      rule -> rule.message
    end
  end

  # Infer which trigger type matches from tool result + context
  defp infer_trigger(_result, %{tool: tool, truncated: true})
       when tool in ["file_edit", "shell", "grep", "read_file"] do
    :after_large_truncation
  end

  defp infer_trigger({:error, _}, %{tool: tool}) when tool in ["file_edit", "write_file"] do
    :after_edit_failure
  end

  defp infer_trigger({:error, _}, %{tool: tool}) when tool in ["shell", "bash", "sh"] do
    :after_shell_failure
  end

  defp infer_trigger({:ok, _}, %{tool: tool}) when tool in ["grep", "search", "rg"] do
    :after_grep
  end

  defp infer_trigger(_, %{tool: tool, error: true}) when tool in ["file_edit", "write_file"] do
    :after_edit_failure
  end

  defp infer_trigger(_, %{tool: tool, error: true}) when tool in ["shell", "bash", "sh"] do
    :after_shell_failure
  end

  defp infer_trigger(_, %{trigger: trigger}) when is_atom(trigger) do
    trigger
  end

  defp infer_trigger(_, _), do: nil

  # --- Private: File parsing ---

  defp parse_guidance_file(path) do
    name = path |> Path.basename(".md") |> String.to_atom()

    case File.read(path) do
      {:ok, content} ->
        {frontmatter, body} = parse_frontmatter(content)

        trigger = Map.get(frontmatter, "trigger", Atom.to_string(name)) |> to_atom_safe()
        priority = Map.get(frontmatter, "priority", 0)

        rule = %{
          name: name,
          trigger: trigger,
          message: String.trim(body),
          priority: priority
        }

        if valid_rule?(rule) do
          {:ok, rule}
        else
          {:error, {:invalid_rule, path}}
        end

      {:error, reason} ->
        {:error, {:read_error, path, reason}}
    end
  end

  # Parse optional YAML-like frontmatter (--- delimited)
  defp parse_frontmatter(content) do
    if String.starts_with?(content, "---\n") do
      case String.split(content, "---\n", parts: 3) do
        ["", fm, body] ->
          frontmatter = parse_simple_yaml(fm)
          {frontmatter, body}

        _ ->
          {%{}, content}
      end
    else
      {%{}, content}
    end
  end

  # Very simple YAML parser for frontmatter — key: value pairs only
  defp parse_simple_yaml(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.map(fn line ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          {String.trim(key), parse_yaml_value(String.trim(value))}

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp parse_yaml_value("true"), do: true
  defp parse_yaml_value("false"), do: false

  defp parse_yaml_value(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> value
    end
  end

  defp valid_rule?(%{trigger: trigger, message: msg}) do
    is_atom(trigger) and is_binary(msg) and msg != ""
  end

  defp valid_rule?(_), do: false

  defp to_atom_safe(str) when is_binary(str) do
    try do
      String.to_atom(str)
    rescue
      _ -> nil
    end
  end

  defp to_atom_safe(atom) when is_atom(atom), do: atom
  defp to_atom_safe(_), do: nil

  # --- Private: Versioning ---

  defp compute_version([]), do: "empty"

  defp compute_version(files) do
    hashes =
      files
      |> Enum.map(fn path ->
        case File.read(path) do
          {:ok, content} -> :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
          {:error, _} -> "missing"
        end
      end)

    :crypto.hash(:sha256, Enum.join(hashes))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end

  defp guidance_dir do
    Path.join(Config.home_dir(), @guidance_subdir)
  end

  defp build_files_map(rules) do
    Map.new(rules, fn rule -> {Atom.to_string(rule.name), rule} end)
  end
end
