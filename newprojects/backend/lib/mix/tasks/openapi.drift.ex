defmodule Mix.Tasks.Openapi.Drift do
  @moduledoc """
  Placeholder OpenAPI drift gate for CI.

  P1-E5 replaces the noop regenerate step with:

      mix openapi.spec.json --spec ImmoWeb.ApiSpec -o priv/static/openapi.json

  @see plan section 6.3, A9
  """
  use Mix.Task

  @shortdoc "Check committed OpenAPI spec matches generated output (placeholder until P1-E5)"

  @spec_path "priv/static/openapi.json"

  @impl Mix.Task
  def run(_args) do
    unless File.exists?(@spec_path) do
      Mix.raise("Missing #{@spec_path}")
    end

    before = File.read!(@spec_path)
    File.write!(@spec_path, before)

    case System.cmd("git", ["diff", "--exit-code", "--", @spec_path], stderr_to_stdout: true) do
      {_, 0} ->
        Mix.shell().info("OpenAPI drift check passed (placeholder; real spec in P1-E5).")

      {output, _} ->
        Mix.raise("""
        OpenAPI drift detected in #{@spec_path}.

        #{output}

        Regenerate and commit when P1-E5 lands (mix openapi.spec.json --spec ImmoWeb.ApiSpec).
        """)
    end
  end
end
