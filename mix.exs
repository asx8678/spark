defmodule Spark.MixProject do
  use Mix.Project

  def project do
    [
      app: :spark,
      version: "4.0.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [ignore_warnings: ".dialyzer_ignore.exs", plt_add_apps: [:mix]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Spark.Application, []}
    ]
  end

  defp deps do
    [
      {:finch, "~> 0.18"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:floki, "~> 0.36"},
      {:phoenix_pubsub, "~> 2.1"},
      {:term_ui, "~> 1.0-rc"},
      {:gen_stage, "~> 1.2"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
