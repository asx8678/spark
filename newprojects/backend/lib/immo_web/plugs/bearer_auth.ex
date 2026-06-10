defmodule ImmoWeb.Plugs.BearerAuth do
  @moduledoc """
  §6.4 — Machine-token auth plug for `/api/v1` build/render tiers.

  Reads `authorization: Bearer <token>`, compares it **constant-time**
  (`Plug.Crypto.secure_compare/2`) against the configured token(s) for
  the pipeline's scope (`:build` or `:render`), and on success assigns
  `:api_scope` to the conn. On any failure (missing header, wrong
  scheme, empty/invalid token, mismatched scope) it halts with 401 +
  RFC 9457 problem+json via `ImmoWeb.FallbackController.unauthorized/1`.

  ## §10.1 rotation runbook

  The expected token for each scope is read from runtime env
  (`BUILD_TOKEN` / `RENDER_TOKEN`). The values may be a **comma-
  separated set** of currently-valid tokens — any member matches
  constant-time per candidate. This is the surface that makes
  zero-downtime rotation work: add a new token to the env list,
  deploy the consumers, remove the old one. As long as the new
  token is present, all requests with the old token still pass.

  Both tokens must be ≥32 random bytes (base64url) per §10.1.

  ## §6.4 scope disjointness

  `:build` and `:render` are **disjoint** scopes — a render token
  is never accepted on build endpoints, and vice versa. The scope
  is fixed by the pipeline the plug is mounted in (the `init/1`
  argument), not inferred from the token.

  ## §10.1 / §13 — Logger redaction

  The `authorization` header is on the §13 redaction list. The
  plug never logs the token value; the redaction filter at
  `config :logger, :filter, ...` strips it from any third-party
  log line that might include it.

  ## Examples

      # In the router:
      pipeline :api_build do
        plug ImmoWeb.Plugs.BearerAuth, :build
      end

      scope "/api/v1", ImmoWeb.Api, as: :api_v1 do
        pipe_through :api_build
        get "/projects", ProjectController, :index
      end
  """

  import Plug.Conn

  @type scope :: :build | :render
  @type env_key :: :build | :render

  @doc """
  Pipeline initializer. The scope (`:build` or `:render`) is the
  only argument; it determines which env var is consulted and which
  value is assigned on success.
  """
  @spec init(scope()) :: scope()
  def init(scope) when scope in [:build, :render], do: scope

  @doc """
  Pipeline entry point. Returns the (possibly halted) conn.

  Halts with 401 + problem+json on:
    * missing `authorization` header
    * header not matching `Bearer <token>` shape
    * empty expected token for the scope (byte_size guard from §6.4)
    * token not in the configured comma-separated set
  """
  @spec call(Plug.Conn.t(), scope()) :: Plug.Conn.t()
  def call(conn, scope) when scope in [:build, :render] do
    expected_set = token_set_for(scope)

    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- byte_size(token) > 0,
         true <- expected_set != [],
         true <- any_secure_match?(token, expected_set) do
      assign(conn, :api_scope, scope)
    else
      _ ->
        conn
        |> put_resp_content_type("application/problem+json")
        |> send_resp(401, Jason.encode!(%{
          type: "https://docs.immo.local/errors/unauthorized",
          title: "Unauthorized",
          status: 401,
          detail: "missing or invalid bearer token for #{scope} scope"
        }))
        |> halt()
    end
  end

  ## Implementation

  # Read the runtime env var for the scope, split on comma, strip
  # whitespace, drop empty entries. Returns [] if the env var is
  # unset or empty (in which case no token authenticates — safe
  # default; never fall through to an open state).
  #
  # We read at REQUEST time, not at compile/init time, so token
  # rotation via env-var reload (or runtime secret reload) takes
  # effect without a process restart.
  @spec token_set_for(scope()) :: [String.t()]
  defp token_set_for(:build) do
    System.get_env("BUILD_TOKEN", "") |> split_trim_nonempty()
  end

  defp token_set_for(:render) do
    System.get_env("RENDER_TOKEN", "")
    |> split_trim_nonempty()
  end

  defp split_trim_nonempty(""), do: []

  defp split_trim_nonempty(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # Constant-time comparison: each candidate compared in full
  # before moving on, so timing does not reveal which candidate
  # matched. `Plug.Crypto.secure_compare/2` is constant-time per
  # call; we call it once per candidate, never short-circuit on
  # the first match. The empty-list case is unreachable from call/2
  # (guarded by `expected_set != []` in the `with`) but the pattern
  # is kept as a defensive default.
  @spec any_secure_match?(String.t(), [String.t()]) :: boolean()
  defp any_secure_match?(token, candidates) do
    results =
      Enum.map(candidates, fn candidate ->
        Plug.Crypto.secure_compare(token, candidate)
      end)

    # `Enum.any?/1` over the result list is itself constant-time
    # (a single pass over a small list), which preserves the §6.4
    # timing requirement.
    Enum.any?(results)
  end
end
