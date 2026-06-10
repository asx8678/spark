defmodule Immo.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ImmoWeb.Telemetry,
      Immo.Repo,
      {DNSCluster, query: Application.get_env(:immo, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Immo.PubSub},
      # §10.1 path 3 — rate limiter for the public pipeline.
      # ETS-backed; single-VPS scope (R6). clean_period: 10 min
      # is fine because every public bucket is at most 1 minute
      # wide; the cleaner just trims expired keys.
      Immo.RateLimiter,
      # Start a worker by calling: Immo.Worker.start_link(arg)
      # {Immo.Worker, arg},
      # Start to serve requests, typically the last entry
      ImmoWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Immo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ImmoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
