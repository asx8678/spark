defmodule Immo.Accounts.UserToken do
  use Ecto.Schema
  import Ecto.Query
  alias Immo.Accounts.UserToken

  @hash_algorithm :sha256
  @rand_size 32

  # It is very important to keep the magic link token expiry short,
  # since someone with access to the email may take over the account.
  @magic_link_validity_in_minutes 15
  @change_email_validity_in_days 7
  @session_validity_in_days 14

  # §13 staff security checklist: 24 h admin session idle timeout.
  # `verify_session_token_query/1` rejects any session token whose
  # `last_seen_at` is older than this window.
  @session_idle_timeout_in_seconds 24 * 60 * 60

  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    field :authenticated_at, :utc_datetime
    # Touched on every authenticated request by Immo.Accounts.touch_user_session_token/1.
    field :last_seen_at, :utc_datetime

    belongs_to :user, Immo.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Generates a token that will be stored in a signed place,
  such as session or cookie. As they are signed, those
  tokens do not need to be hashed.
  """
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    dt = user.authenticated_at || DateTime.utc_now(:second)
    now = DateTime.utc_now(:second)

    {token,
     %UserToken{
       token: token,
       context: "session",
       user_id: user.id,
       authenticated_at: dt,
       last_seen_at: now
     }}
  end

  @doc """
  Checks if the session token is valid and returns its underlying lookup query.

  The query returns the user found by the token, if any, along with the
  token's creation time. The token is valid if it matches the value in the
  database, has not exceeded the absolute age (`@session_validity_in_days`),
  and was last seen within the idle window
  (`@session_idle_timeout_in_seconds`).
  """
  def verify_session_token_query(token) do
    query =
      from token in by_token_and_context_query(token, "session"),
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(@session_validity_in_days, "day"),
        where: token.last_seen_at > ago(@session_idle_timeout_in_seconds, "second"),
        select: {%{user | authenticated_at: token.authenticated_at}, token.inserted_at}

    {:ok, query}
  end

  @doc """
  Builds a token and its hash to be delivered to the user's email.
  """
  def build_email_token(user, context) do
    build_hashed_token(user, context, user.email)
  end

  defp build_hashed_token(user, context, sent_to) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %UserToken{
       token: hashed_token,
       context: context,
       sent_to: sent_to,
       user_id: user.id
     }}
  end

  @doc """
  Checks if the magic link token is valid and returns its underlying lookup query.
  """
  def verify_magic_link_token_query(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, "login"),
            join: user in assoc(token, :user),
            where: token.inserted_at > ago(^@magic_link_validity_in_minutes, "minute"),
            where: token.sent_to == user.email,
            select: {user, token}

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Checks if the change email token is valid and returns its underlying lookup query.
  """
  def verify_change_email_token_query(token, "change:" <> _ = context) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, context),
            where: token.inserted_at > ago(@change_email_validity_in_days, "day"),
            select: token

        {:ok, query}

      :error ->
        :error
    end
  end

  defp by_token_and_context_query(token, context) do
    from UserToken, where: [token: ^token, context: ^context]
  end
end
