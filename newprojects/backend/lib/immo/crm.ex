defmodule Immo.CRM do
  @moduledoc """
  CRM context — §6.1 bounded responsibility.

  Owns:
    * `inquiries` (§5.7) — leads, status workflow, retention.
    * The §5.7 retention/rotation policy (P1-E6) for closed inquiries.

  Out of scope for P1-E2.5 (P1-E2.5 is the typespecs + base
  changesets delivery only):
    * The public inquiry submission form (P1-E6).
    * The auto-reply email acknowledgement (P1-E6).
    * The retention/rotation Oban job (P1-E6).
  """

  alias Immo.CRM.Inquiry
  alias Immo.Repo

  @doc """
  Get an inquiry by id (raises if not found).
  """
  @spec get_inquiry!(binary()) :: Inquiry.t()
  def get_inquiry!(id), do: Repo.get!(Inquiry, id)

  @doc """
  List inquiries, newest first. P1-E6 will add filter helpers
  (`list_for_listing/1`, `list_for_user/1`, `list_by_status/1`).
  """
  @spec list_inquiries(keyword()) :: [Inquiry.t()]
  def list_inquiries(opts \\ []) do
    import Ecto.Query, only: [order_by: 2, limit: 2, offset: 2]

    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    Inquiry
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Insert a new inquiry. P1-E2.5 skeleton: wraps the changeset in
  `Repo.transact/1` and writes the audit_log row via `Immo.Audit`.
  P1-E6 adds the auto-reply email send and the retention-purge
  Oban schedule.
  """
  @spec create_inquiry(map(), keyword()) :: {:ok, Inquiry.t()} | {:error, Ecto.Changeset.t()}
  def create_inquiry(attrs, opts \\ []) do
    Repo.transact(fn ->
      with {:ok, inquiry} <-
             %Inquiry{} |> Inquiry.create_changeset(attrs) |> Repo.insert(),
           :ok <-
             Immo.Audit.log_mutation(
               actor_user: opts[:actor_user],
               action: "create",
               entity: inquiry,
               diff: Immo.Audit.create_diff(inquiry)
             ) do
        {:ok, inquiry}
      end
    end)
  end

  @doc """
  Move an inquiry through the status workflow (`new | contacted |
  closed`). Stubs out for P1-E2.5; P1-E6 wires the email-on-
  transition + the retention-purge trigger.
  """
  @spec transition_status(Inquiry.t(), String.t(), keyword()) ::
          {:ok, Inquiry.t()} | {:error, Ecto.Changeset.t() | :forbidden_transition}
  def transition_status(inquiry, new_status, opts \\ [])
      when new_status in ~w(new contacted closed) do
    Repo.transact(fn ->
      old = inquiry

      case Ecto.Changeset.change(inquiry, %{status: new_status}) |> Repo.update() do
        {:ok, updated} ->
          Immo.Audit.log_mutation(
            actor_user: opts[:actor_user],
            action: "transition",
            entity: updated,
            diff:
              Immo.Audit.update_diff(
                old,
                updated,
                Ecto.Changeset.change(old, %{status: new_status})
              )
          )

          {:ok, updated}

        error ->
          error
      end
    end)
  end
end
