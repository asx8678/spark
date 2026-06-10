defmodule Mix.Tasks.Openapi.Drift do
  @moduledoc """
  §6.3 / P1-E5.5 — OpenAPI drift gate for CI.

  The §16 release-gate rule is "spec drift fails CI": a
  controller change without a regenerated (and committed)
  `priv/static/openapi.json` must not pass CI. This task:

    1. Regenerates the spec from `ImmoWeb.ApiSpec` to a
       scratch path (the generator overwrites in place; the
       scratch path keeps the committed file untouched for
       the diff comparison).
    2. `git diff --exit-code` against the scratch file —
       any difference raises.
    3. On success, exits 0 with a one-line summary.

  ## Run

      mix openapi.drift

  ## CI integration

  Add to the §15.2 contract-test job *after* the API tests
  pass. The gate is fast (no DB, no Phoenix boot) and
  deterministic.

  ## Why a separate task instead of inlining into CI

  Three reasons:

    * `git diff --exit-code` is the only "is the spec in sync
      with the source?" check that catches a regenerated
      but-uncommitted file (which a `cmp` would miss because
      the bytes are identical, but the file is dirty).
    * The error message names the file + the diff so the
      developer knows exactly what to commit.
    * Local developers can run `mix openapi.drift` before
      pushing, not just on CI.
  """
  use Mix.Task

  @shortdoc "Fail if regenerated OpenAPI spec differs from the committed one"

  @spec_path "priv/static/openapi.json"
  @scratch_path "priv/static/openapi.drift.json"

  @impl Mix.Task
  def run(_args) do
    unless File.exists?(@spec_path) do
      Mix.raise("Missing #{@spec_path}; commit the initial spec first.")
    end

    # Regenerate to a scratch path so the diff compares the
    # committed file against a fresh build. The upstream
    # `mix openapi.spec.json` task takes the output path as a
    # positional argument (no `-o` flag).
    Mix.Task.run("openapi.spec.json", ["--spec", "ImmoWeb.ApiSpec", @scratch_path])

    case System.cmd("git", ["diff", "--no-index", "--exit-code", @spec_path, @scratch_path],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        Mix.shell().info("OpenAPI drift check passed.")
        File.rm!(@scratch_path)
        :ok

      {output, _code} ->
        File.rm!(@scratch_path)

        Mix.raise("""
        OpenAPI drift detected — regenerated spec differs from the committed #{@spec_path}.

        #{output}

        Run `mix openapi.spec.json --spec ImmoWeb.ApiSpec priv/static/openapi.json` and commit the result.
        """)
    end
  end
end
