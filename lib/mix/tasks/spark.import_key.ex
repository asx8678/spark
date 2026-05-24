defmodule Mix.Tasks.Spark.ImportKey do
  @moduledoc """
  Imports a plaintext API key file into Spark's encrypted secrets storage.

  The key is read from a file, encrypted via `Spark.Config.Secrets`, and
  verified by decrypting it back. On success the plaintext source file is
  deleted (unless `--keep-file` is given).

  ## Usage

      mix spark.import_key                           # defaults: wafer, ~/.spark/wafer_api_key.txt
      mix spark.import_key --provider wafer           # explicit provider
      mix spark.import_key --file /tmp/my_key.txt     # explicit file
      mix spark.import_key --keep-file                # don't delete source file

  ## Options

    * `--provider`  - Provider name (default: `wafer`). The secret key atom
      is constructed as `${provider}_api_key`.
    * `--file`      - Path to the plaintext key file (default:
      `~/.spark/${provider}_api_key.txt`).
    * `--keep-file` - Keep the plaintext file after successful import.
  """

  use Mix.Task

  @shortdoc "Imports a plaintext API key into encrypted secrets storage"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start", [])

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [provider: :string, file: :string, keep_file: :boolean],
        aliases: [p: :provider, f: :file, k: :keep_file]
      )

    provider = opts[:provider] || "wafer"
    keep_file? = opts[:keep_file] || false

    file =
      case opts[:file] do
        nil -> Path.join(Spark.Config.home_dir(), "#{provider}_api_key.txt")
        path -> expand_home(path)
      end

    secret_key = String.to_atom("#{provider}_api_key")

    import_key(file, secret_key, provider, keep_file?)
  end

  defp import_key(file, secret_key, provider, keep_file?) do
    with {:ok, raw} <- read_key_file(file),
         key <- parse_key_value(String.trim(raw)),
         :ok <- validate_key(key, file),
         :ok <- Spark.Config.Secrets.put_secret(secret_key, key),
         {:ok, stored} <- verify_secret(secret_key) do
      Mix.shell().info([
        [:green, "✓ ", :reset],
        "Imported :#{secret_key} (provider: #{provider})",
        [:bright, "  #{mask_key(stored)}", :reset]
      ])

      unless keep_file? do
        File.rm!(file)
        Mix.shell().info("  Deleted plaintext file: #{file}")
      end

      :ok
    else
      {:error, reason} ->
        Mix.shell().error("✗ Import failed: #{reason}")
        Mix.shell().info("  Plaintext file preserved: #{file}")

        Mix.raise("spark.import_key failed")
    end
  end

  defp read_key_file(file) do
    expanded = expand_home(file)

    case File.read(expanded) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, "Key file not found: #{expanded}"}
      {:error, :eacces} -> {:error, "Permission denied: #{expanded}"}
      {:error, reason} -> {:error, "Cannot read #{expanded}: #{inspect(reason)}"}
    end
  end

  # Handles both bare key values and "KEY_NAME = value" format
  # (e.g. from .env files or copy-paste from config snippets)
  defp parse_key_value(content) do
    case String.split(content, " = ", parts: 2) do
      [_key_name, value] ->
        String.trim(value)

      _ ->
        case String.split(content, "=", parts: 2) do
          [_key_name, value] -> String.trim(value)
          _ -> content
        end
    end
  end

  defp validate_key("", file) do
    {:error, "Key file is empty: #{file}"}
  end

  defp validate_key(_key, _file), do: :ok

  defp verify_secret(secret_key) do
    case Spark.Config.Secrets.get_secret(secret_key) do
      nil -> {:error, "Verification failed: secret not found after write"}
      value -> {:ok, value}
    end
  end

  defp mask_key(key) when byte_size(key) >= 4 do
    <<prefix::binary-size(4), _rest::binary>> = key
    "#{prefix}...***"
  end

  defp mask_key(key) when byte_size(key) > 0, do: "***"

  defp expand_home(path) do
    String.replace_prefix(path, "~", System.user_home())
  end
end
