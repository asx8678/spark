import Config

config :logger, :console,
  level: :info,
  format: "[$level] $message\n"

if System.get_env("SPARK_DEBUG") == "true" do
  config :logger, :console, level: :debug
end

# Streaming adapter: :direct (default) or :gen_stage
# :direct — original Req into: callback (push-based)
# :gen_stage — demand-driven GenStage pipeline (backpressure)
config :spark, :streaming_adapter, :direct
