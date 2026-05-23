import Config

config :logger, :console,
  level: :info,
  format: "[$level] $message\n"

if System.get_env("SPARK_DEBUG") == "true" do
  config :logger, :console, level: :debug
end
