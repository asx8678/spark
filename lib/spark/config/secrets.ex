defmodule Spark.Config.Secrets do
  @moduledoc """
  AES-256-GCM encrypted secret storage for Spark.

  Secrets are stored at ~/.spark/secrets.enc in an encrypted format
  using PBKDF2 key derivation and AES-256-GCM authenticated encryption.

  Rules:
    - Never log raw secrets
    - Never include raw secrets in Bronze memory
    - Never show raw secrets in CLI
    - Decryption failures return safe errors
    - Corrupt secrets file doesn't crash the app
    - Secrets reload should not require app restart

  The passphrase is sourced from:
    1. Application env `:spark, :secrets_passphrase`
    2. Environment variable `SPARK_SECRETS_PASSPHRASE`
    3. Default: "spark-default" (for dev mode only)
  """

  use Agent

  @iterations 600_000
  @key_length 32
  @iv_length 12
  @file_version 1

  @doc """
  Starts the Secrets Agent.
  """
  @spec start_link(term()) :: {:ok, pid()} | {:error, term()}
  def start_link(_opts \\ []) do
    # Self-check: Process.whereis(__MODULE__) is correct for named singletons
    # (not session-scoped). Registry lookup adds no value here. (spark-ard.19)
    case Process.whereis(__MODULE__) do
      nil ->
        initial_state = %{
          cache: %{},
          passphrase: passphrase(),
          home_dir: Spark.Config.home_dir()
        }

        Agent.start_link(fn -> initial_state end, name: __MODULE__)

      pid ->
        {:ok, pid}
    end
  end

  defp ensure_agent_started_only do
    # Self-check: Process.whereis(__MODULE__) is correct for named singletons
    # (not session-scoped). Registry lookup adds no value here. (spark-ard.19)
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  @doc """
  Returns the current passphrase from configured sources.
  """
  @spec passphrase() :: String.t()
  def passphrase do
    Application.get_env(:spark, :secrets_passphrase) ||
      System.get_env("SPARK_SECRETS_PASSPHRASE") ||
      "spark-default"
  end

  @doc """
  Encrypts and stores a secret value under the given key.
  """
  @spec put_secret(atom() | String.t(), String.t()) :: :ok
  def put_secret(key, value) do
    ensure_agent_started_only()
    key_str = to_string(key)

    # Sanitize: strip accidental "key = value" prefix from .env-style imports
    value = sanitize_secret_value(value)

    secrets = read_secrets_map()
    encrypted = encrypt(value)
    secrets = Map.put(secrets, key_str, encrypted)
    write_secrets_map!(secrets)

    current_pass = passphrase()
    current_home = Spark.Config.home_dir()

    Agent.update(__MODULE__, fn state ->
      state =
        if state.passphrase != current_pass or state.home_dir != current_home do
          %{cache: %{}, passphrase: current_pass, home_dir: current_home}
        else
          state
        end

      new_cache = Map.put(state.cache, key_str, value)
      %{state | cache: new_cache}
    end)

    :ok
  end

  @doc """
  Decrypts and returns a secret value by key.
  Returns nil if not found or decryption fails.
  Never raises on decryption errors.
  """
  @spec get_secret(atom() | String.t()) :: String.t() | nil
  def get_secret(key) do
    ensure_agent_started_only()
    key_str = to_string(key)
    current_pass = passphrase()
    current_home = Spark.Config.home_dir()

    Agent.get_and_update(__MODULE__, fn state ->
      state =
        if state.passphrase != current_pass or state.home_dir != current_home do
          %{cache: %{}, passphrase: current_pass, home_dir: current_home}
        else
          state
        end

      case Map.fetch(state.cache, key_str) do
        {:ok, value} ->
          {value, state}

        :error ->
          value = decrypt_from_disk(key_str)
          new_cache = Map.put(state.cache, key_str, value)
          {value, %{state | cache: new_cache}}
      end
    end)
  end

  defp decrypt_from_disk(key_str) do
    secrets = read_secrets_map()

    case Map.get(secrets, key_str) do
      nil ->
        nil

      encrypted_entry ->
        case decrypt(encrypted_entry) do
          {:ok, value} -> value
          {:error, _reason} -> nil
        end
    end
  end

  @doc """
  Deletes a secret by key.
  """
  @spec delete_secret(atom() | String.t()) :: :ok
  def delete_secret(key) do
    ensure_agent_started_only()
    key_str = to_string(key)

    secrets = read_secrets_map()
    secrets = Map.delete(secrets, key_str)
    write_secrets_map!(secrets)

    current_pass = passphrase()
    current_home = Spark.Config.home_dir()

    Agent.update(__MODULE__, fn state ->
      state =
        if state.passphrase != current_pass or state.home_dir != current_home do
          %{cache: %{}, passphrase: current_pass, home_dir: current_home}
        else
          state
        end

      new_cache = Map.delete(state.cache, key_str)
      %{state | cache: new_cache}
    end)

    :ok
  end

  @doc """
  Lists all secret keys without values.
  """
  @spec list_secret_keys() :: [String.t()]
  def list_secret_keys do
    secrets = read_secrets_map()
    Map.keys(secrets)
  end

  @doc """
  Encrypts a value using AES-256-GCM with PBKDF2-derived key.
  Returns a map with the encrypted payload and metadata.
  """
  @spec encrypt(String.t()) :: map()
  def encrypt(plaintext) when is_binary(plaintext) do
    salt = :crypto.strong_rand_bytes(16)
    iv = :crypto.strong_rand_bytes(@iv_length)
    key = derive_key(passphrase(), salt)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        iv,
        plaintext,
        <<>>,
        true
      )

    %{
      "version" => @file_version,
      "kdf" => "pbkdf2_hmac_sha256",
      "salt" => Base.encode64(salt),
      "iv" => Base.encode64(iv),
      "tag" => Base.encode64(tag),
      "ciphertext" => Base.encode64(ciphertext)
    }
  end

  @doc """
  Decrypts a value from the encrypted map format.
  Returns {:ok, plaintext} or {:error, reason}.
  """
  @spec decrypt(map()) :: {:ok, String.t()} | {:error, term()}
  def decrypt(%{
        "version" => @file_version,
        "kdf" => "pbkdf2_hmac_sha256",
        "salt" => salt_b64,
        "iv" => iv_b64,
        "tag" => tag_b64,
        "ciphertext" => ct_b64
      }) do
    try do
      salt = Base.decode64!(salt_b64)
      iv = Base.decode64!(iv_b64)
      tag = Base.decode64!(tag_b64)
      ciphertext = Base.decode64!(ct_b64)
      key = derive_key(passphrase(), salt)

      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             iv,
             ciphertext,
             <<>>,
             tag,
             false
           ) do
        :error -> {:error, :decryption_failed}
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
      end
    rescue
      _ -> {:error, :decryption_error}
    end
  end

  @spec decrypt(term()) :: {:error, term()}
  def decrypt(_), do: {:error, :invalid_format}

  # --- Private helpers ---

  defp derive_key(pass, salt) do
    :crypto.pbkdf2_hmac(:sha256, pass, salt, @iterations, @key_length)
  end

  defp secrets_path do
    Path.join(Spark.Config.home_dir(), "secrets.enc")
  end

  defp read_secrets_map do
    path = secrets_path()

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, secrets} when is_map(secrets) -> secrets
          {:error, _} -> %{}
        end

      {:error, :enoent} ->
        %{}

      {:error, _} ->
        %{}
    end
  end

  defp write_secrets_map!(secrets) do
    path = secrets_path()
    File.mkdir_p!(Path.dirname(path))
    json = Jason.encode!(secrets, pretty: true)
    File.write!(path, json)
  end

  # Strips accidental "key_name = value" prefix from .env-style imports.
  # Only applies when the value starts with a word followed by " = ".
  defp sanitize_secret_value(value) when is_binary(value) do
    case String.split(value, " = ", parts: 2) do
      [prefix, actual] when is_binary(actual) and actual != "" ->
        # Only strip if the prefix looks like a key name (no spaces, no special chars)
        if Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, prefix) do
          String.trim(actual)
        else
          value
        end

      _ ->
        value
    end
  end

  defp sanitize_secret_value(value), do: value
end
