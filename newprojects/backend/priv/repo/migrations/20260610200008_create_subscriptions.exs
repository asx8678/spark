defmodule Immo.Repo.Migrations.CreateSubscriptions do
  @moduledoc """
  P1-E2.1 §5.9 — `subscriptions`.

  Per §5.9:
    * `plan` enum: `basic | featured | enterprise`
    * `status` enum: `trialing | active | past_due | canceled`
    * `provider` enum: `stripe | cmi | manual`
    * `provider_subscription_id` (per-provider identifier — used for
      webhook reconciliation)

  The enums are stored as strings; the allowlist is enforced at the
  changeset level (P1-E2.2) so the DB stays light. The `cancel_at_period_end`
  boolean is the Stripe/Cmi-style "cancel scheduled at end of current period"
  flag.
  """

  use Ecto.Migration

  def change do
    create table(:subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :developer_id, references(:developers, type: :binary_id, on_delete: :delete_all),
        null: false

      add :plan, :string, null: false
      add :status, :string, null: false

      add :provider, :string, null: false
      add :provider_subscription_id, :string

      add :current_period_start, :timestamptz
      add :current_period_end, :timestamptz
      add :cancel_at_period_end, :boolean, default: false, null: false

      timestamps(type: :timestamptz)
    end

    # A developer's active subscription lookup: the §5.13
    # `Catalog.published/1` billing gate uses this index path
    # (developer_id, status, current_period_end).
    create index(:subscriptions, [:developer_id, :status, :current_period_end])

    # Provider's per-merchant subscription id is unique (per provider)
    # so webhook idempotency works at the DB level too.
    create index(:subscriptions, [:provider, :provider_subscription_id], unique: true)
  end
end
