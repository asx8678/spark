defmodule Immo.Billing.Subscription do
  @moduledoc """
  `subscriptions` (§5.9) — a developer's plan state with a provider.

  Per §5.9:
    * `developer_id` fk.
    * `plan` enum: `basic | featured | enterprise`.
    * `status` enum: `trialing | active | past_due | canceled`.
    * `provider` enum: `stripe | cmi | manual`.
    * `provider_subscription_id` (per-provider id, used for webhook
      reconciliation — the unique index on
      `(provider, provider_subscription_id)` is the DB-level
      idempotency net).
    * `current_period_start`, `current_period_end` (the
      §5.13 / `Catalog.published/1` billing gate uses these).
    * `cancel_at_period_end` boolean.

  The `Immo.Billing` context (P1-E2.5) owns the provider adapters
  and webhook reconciliation; P1-E2.3's `Catalog.published/1`
  consults this table when `BILLING_ENFORCED` is true.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "subscriptions" do
    belongs_to :developer, Immo.Catalog.Developer

    field :plan, :string
    field :status, :string

    field :provider, :string
    field :provider_subscription_id, :string

    field :current_period_start, :utc_datetime
    field :current_period_end, :utc_datetime
    field :cancel_at_period_end, :boolean, default: false

    timestamps(type: :utc_datetime)
  end
end
