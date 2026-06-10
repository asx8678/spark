defmodule Immo.Billing.Payment do
  @moduledoc """
  `payments` (§5.9) — successful (or attempted) charges against a
  subscription.

  Per §5.9:
    * `subscription_id` fk.
    * `amount` numeric(14,2), `currency` char(3).
    * `status` enum: `pending | succeeded | failed | refunded`.
    * `provider` (matches `subscriptions.provider` for the same row).
    * `provider_payment_id` — unique per provider; the unique index
      on `(provider, provider_payment_id)` is the DB-level
      idempotency net for webhook replays.
    * `invoice_url` — provider-hosted invoice page.
    * `paid_at` — wall-clock when the charge settled.
    * `raw_event` jsonb — the provider's full payload, kept for
      audit / debugging.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "payments" do
    belongs_to :subscription, Immo.Billing.Subscription

    field :amount, :decimal
    field :currency, :string

    field :status, :string

    field :provider, :string
    field :provider_payment_id, :string

    field :invoice_url, :string
    field :paid_at, :utc_datetime

    field :raw_event, :map

    timestamps(type: :utc_datetime)
  end
end
