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

  ## P1-E2.5 changesets

  The base create_changeset/2 enforces:
    * `amount` and `currency` present.
    * `currency` is 3 uppercase letters (ISO-4217).
    * `status` and `provider` allowlist.
    * The `(provider, provider_payment_id)` unique constraint
      (DB-level — surfaced as a changeset unique_constraint for
      friendly error messages).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending succeeded failed refunded)
  @providers ~w(stripe cmi manual)

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

  @doc "Allowed status values per §5.9."
  def statuses, do: @statuses

  @doc "Allowed provider values per §5.9."
  def providers, do: @providers

  @doc """
  Base create changeset. The webhook handler (P6) writes new
  payments; the manual admin path (P1-E3) uses this too.
  """
  def create_changeset(payment, attrs) do
    payment
    |> cast(attrs, [
      :subscription_id,
      :amount,
      :currency,
      :status,
      :provider,
      :provider_payment_id,
      :invoice_url,
      :paid_at,
      :raw_event
    ])
    |> validate_required([:subscription_id, :amount, :currency, :status, :provider])
    |> validate_number(:amount, greater_than: 0)
    |> validate_length(:currency, is: 3)
    |> validate_format(:currency, ~r/^[A-Z]{3}$/, message: "must be uppercase ISO-4217")
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:provider, @providers)
    |> unique_constraint([:provider, :provider_payment_id])
    |> foreign_key_constraint(:subscription_id)
  end
end
