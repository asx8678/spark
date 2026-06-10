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
  consults this table when `BILLING_ENFORCED` is on.

  ## P1-E2.5 changesets

  The base create_changeset/2 enforces:
    * `plan` and `status` allowlist (§5.9 enum strings).
    * `provider` allowlist.
    * `current_period_end >= current_period_start` (sanity).
    * `cancel_at_period_end` is a boolean (DB default `false`).

  The webhook handler (P6) and the §11 dunning flow build new
  subscription rows on activation / cancellation — those will
  compose this changeset.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @plans ~w(basic featured enterprise)
  @statuses ~w(trialing active past_due canceled)
  @providers ~w(stripe cmi manual)

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

  @doc "Allowed plan values per §5.9."
  def plans, do: @plans

  @doc "Allowed status values per §5.9."
  def statuses, do: @statuses

  @doc "Allowed provider values per §5.9."
  def providers, do: @providers

  @doc """
  Base create changeset. The webhook handler (P6) and the §11
  dunning flow build new rows; the admin UI (P1-E3) uses this too
  for the "manual" provider path.
  """
  def create_changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :developer_id,
      :plan,
      :status,
      :provider,
      :provider_subscription_id,
      :current_period_start,
      :current_period_end,
      :cancel_at_period_end
    ])
    |> validate_required([:developer_id, :plan, :status, :provider])
    |> validate_inclusion(:plan, @plans)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:provider, @providers)
    |> validate_period_order()
    |> foreign_key_constraint(:developer_id)
  end

  # The `current_period_end` must be at-or-after
  # `current_period_start`. Both fields are nullable (a `manual`
  # subscription with no scheduled billing cycle has neither),
  # but when both are set the invariant must hold.
  defp validate_period_order(changeset) do
    start_at = get_field(changeset, :current_period_start)
    end_at = get_field(changeset, :current_period_end)

    case {start_at, end_at} do
      {%DateTime{}, %DateTime{}} ->
        if DateTime.compare(start_at, end_at) in [:gt] do
          add_error(changeset, :current_period_end, "must be at or after current_period_start")
        else
          changeset
        end

      _ ->
        changeset
    end
  end
end
