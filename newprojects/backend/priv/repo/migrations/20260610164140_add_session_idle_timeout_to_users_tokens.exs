defmodule Immo.Repo.Migrations.AddSessionIdleTimeoutToUsersTokens do
  use Ecto.Migration

  # §13 staff security checklist requires a 24 h admin session idle timeout.
  # `last_seen_at` is touched on every authenticated request via the auth
  # pipeline; tokens older than the idle window are rejected by the verify
  # query. Absolute session age is the existing `@session_validity_in_days`
  # cap (14 d).
  def change do
    alter table(:users_tokens) do
      add :last_seen_at, :utc_datetime
    end

    # Backfill: existing rows have no recorded last activity. Setting it to
    # inserted_at means they are immediately subject to the idle cap from
    # the moment of this migration — which is the safe default (force re-login
    # on upgrade rather than granting a long free pass).
    execute("UPDATE users_tokens SET last_seen_at = inserted_at WHERE last_seen_at IS NULL")
  end
end
