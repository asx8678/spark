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

  @iterations 600_000
  @key_length 32
  @iv_length 12
  @file_version 1

  @doc """
  Returns the current passphrase from configured sources.
  """
  def passphrase do
    Application.get_env(:spark, :secrets_passphrase) ||
      System.get_env("SPARK_SECRETS_PASSPHRASE") ||
      "spark-default"
  end

  @doc """
  Encrypts and stores a secret value under the given key.
  """
  def put_secret(key, value) do
    secrets = read_secrets_map()
    encrypted = encrypt(value)
    secrets = Map.put(secrets, to_string(key), encrypted)
    write_secrets_map!(secrets)
    :ok
  end

  @doc """
  Decrypts and returns a secret value by key.
  Returns nil if not found or decryption fails.
  Never raises on decryption errors.
  """
  def get_secret(key) do
    secrets = read_secrets_map()
    case Map.get(secrets, to_string(key)) do
      nil -> nil
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
  def delete_secret(key) do
    secrets = read_secrets_map()
    secrets = Map.delete(secrets, to_string(key))
    write_secrets_map!(secrets)
    :ok
  end

  @doc """
  Lists all secret keys without values.
  """
  def list_secret_keys do
    secrets = read_secrets_map()
    Map.keys(secrets)
  end

  @doc """
  Encrypts a value using AES-256-GCM with PBKDF2-derived key.
  Returns a map with the encrypted payload and metadata.
  """
  def encrypt(plaintext) when is_binary(plaintext) do
    salt = :crypto.strong_rand_bytes(16)
    iv = :crypto.strong_rand_bytes(@iv_length)
    key = derive_key(passphrase(), salt)

    {ciphertext, tag} = :crypto.crypto_one_time_aead(
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

      {:error, :enoent} -> %{}
      {:error, _} -> %{}
    end
  end

  defp write_secrets_map!(secrets) do
    path = secrets_path()
    File.mkdir_p!(Path.dirname(path))
    json = Jason.encode!(secrets, pretty: true)
    File.write!(path, json)
  end
end
