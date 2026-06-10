defmodule Immo.Repo.Migrations.CreatePayments do
  @moduledoc """
  P1-E2.1 §5.9 — `payments`.

  The `provider_payment_id` is the per-provider payment id and is
  unique — the source of truth for webhook idempotency (§11). If the
  same webhook fires twice, the second insert collides on this index
  and the P1-E2.2 changeset's unique_constraint catches it.

  `raw_event` jsonb stores the provider's full payload for audit /
  debugging. `invoice_url` is the per-invoice URL returned by the
  provider (Stripe hosted invoice page, etc.).
  """

  use Ecto.Migration

  def change do
    create table(:payments, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :subscription_id,
          references(:subscriptions, type: :binary_id, on_delete: :restrict),
          null: false

      add :amount, :decimal, precision: 14, scale: 2, null: false
      add :currency, :string, size: 3, null: false

      add :status, :string, null: false

      add :provider, :string, null: false
      add :provider_payment_id, :string

      add :invoice_url, :string
      add :paid_at, :timestamptz

      add :raw_event, :map

      timestamps(type: :timestamptz)
    end

    # §5.9: provider_payment_id unique (idempotency).
    create unique_index(:payments, [:provider, :provider_payment_id])

    # The subscription history view is the main read path.
    create index(:payments, [:subscription_id, :paid_at])
  end
end
