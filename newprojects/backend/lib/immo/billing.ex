defmodule Immo.Billing do
  @moduledoc """
  Billing context — §6.1 bounded responsibility.

  Owns:
    * `subscriptions` (§5.9) — a developer's plan state with a
      provider. The §5.13 / `Catalog.published/1` billing gate
      consults this table when `BILLING_ENFORCED` is on.
    * `payments` (§5.9) — webhook-received charges against a
      subscription. The DB-level
      `(provider, provider_payment_id)` unique index is the
      idempotency net.
    * Provider adapters — Stripe, Cmi, manual (P6).
    * Webhook reconciliation (P6).

  Out of scope for P1-E2.5 (P1-E2.5 is typespecs + base
  changesets only):
    * The Stripe / Cmi / manual adapters (P6).
    * The webhook handlers (P6).
    * The admin "mark paid" UI (P1-E3.5).
  """

  alias Immo.Billing.{Payment, Subscription}
  alias Immo.Repo

  ## Subscriptions

  @doc "Get a subscription by id (raises if not found)."
  @spec get_subscription!(binary()) :: Subscription.t()
  def get_subscription!(id), do: Repo.get!(Subscription, id)

  @doc """
  List subscriptions for a developer. The §5.13 billing gate joins
  on the latest row; the P1-E2.5 baseline is "all rows" — P6
  layers in the `ORDER BY inserted_at DESC LIMIT 1` filter as
  part of the latest-subscription subquery.
  """
  @spec list_subscriptions_for_developer(binary()) :: [Subscription.t()]
  def list_subscriptions_for_developer(developer_id) when is_binary(developer_id) do
    import Ecto.Query, only: [where: 3, order_by: 2]

    Subscription
    |> where([s], s.developer_id == ^developer_id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  @doc """
  Insert a new subscription. P1-E2.5 skeleton: wraps the changeset
  in `Repo.transact/1` and writes the audit_log row. The P6
  webhook handler calls this on `customer.subscription.created`.
  """
  @spec create_subscription(map(), keyword()) ::
          {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def create_subscription(attrs, opts \\ []) do
    Repo.transact(fn ->
      with {:ok, sub} <-
             %Subscription{} |> Subscription.create_changeset(attrs) |> Repo.insert(),
           :ok <-
             Immo.Audit.log_mutation(
               actor_user: opts[:actor_user],
               action: "create",
               entity: sub,
               diff: Immo.Audit.create_diff(sub)
             ) do
        {:ok, sub}
      end
    end)
  end

  ## Payments

  @doc "Get a payment by id (raises if not found)."
  @spec get_payment!(binary()) :: Payment.t()
  def get_payment!(id), do: Repo.get!(Payment, id)

  @doc """
  Insert a new payment row. The P6 webhook handler calls this on
  `invoice.payment_succeeded` (Stripe) or equivalent. The
  `(provider, provider_payment_id)` unique index makes webhook
  replays idempotent at the DB level; the changeset surfaces a
  friendly error message when a duplicate is attempted.
  """
  @spec create_payment(map(), keyword()) :: {:ok, Payment.t()} | {:error, Ecto.Changeset.t()}
  def create_payment(attrs, opts \\ []) do
    Repo.transact(fn ->
      with {:ok, payment} <-
             %Payment{} |> Payment.create_changeset(attrs) |> Repo.insert(),
           :ok <-
             Immo.Audit.log_mutation(
               actor_user: opts[:actor_user],
               action: "create",
               entity: payment,
               diff: Immo.Audit.create_diff(payment)
             ) do
        {:ok, payment}
      end
    end)
  end
end
