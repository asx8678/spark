defmodule Spark.HotReload.Reloadable do
  @moduledoc """
  Behaviour for reload-aware modules.

  Modules that need controlled reload semantics implement this behaviour
  to define their reload key, version tracking, validation, and
  before/after lifecycle hooks.
  """

  @type component_key :: {atom(), atom() | String.t()}

  @callback reload_key() :: component_key()
  @callback version() :: String.t()
  @callback validate_reload(opts :: map()) :: :ok | {:error, term()}
  @callback before_reload(state :: term()) :: {:ok, term()} | {:error, term()}
  @callback after_reload(state :: term(), metadata :: map()) :: {:ok, term()} | {:error, term()}

  @doc """
  Checks if a module implements the Spark.HotReload.Reloadable behaviour.

  Returns true if the module is loaded and exports all required callbacks.
  """
  @spec implements?(module()) :: boolean()
  def implements?(module) when is_atom(module) do
    with true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :reload_key, 0),
         true <- function_exported?(module, :version, 0),
         true <- function_exported?(module, :validate_reload, 1),
         true <- function_exported?(module, :before_reload, 1),
         true <- function_exported?(module, :after_reload, 2) do
      true
    else
      _ -> false
    end
  end

  @doc """
  Calls validate_reload/1 on a module implementing this behaviour.
  Returns :ok or {:error, reason}.
  """
  @spec validate(module(), map()) :: :ok | {:error, term()}
  def validate(module, opts \\ %{}) when is_atom(module) do
    if implements?(module) do
      module.validate_reload(opts)
    else
      {:error, {:not_reloadable, module}}
    end
  end

  @doc """
  Calls before_reload/1 on a module implementing this behaviour.
  Returns {:ok, state} or {:error, reason}.
  """
  @spec before_reload(module(), term()) :: {:ok, term()} | {:error, term()}
  def before_reload(module, state) when is_atom(module) do
    if implements?(module) do
      module.before_reload(state)
    else
      {:error, {:not_reloadable, module}}
    end
  end

  @doc """
  Calls after_reload/2 on a module implementing this behaviour.
  Returns {:ok, state} or {:error, reason}.
  """
  @spec after_reload(module(), term(), map()) :: {:ok, term()} | {:error, term()}
  def after_reload(module, state, metadata) when is_atom(module) do
    if implements?(module) do
      module.after_reload(state, metadata)
    else
      {:error, {:not_reloadable, module}}
    end
  end
end
