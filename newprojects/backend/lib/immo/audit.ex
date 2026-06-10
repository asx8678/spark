defmodule Immo.Audit do
  @moduledoc """
  Audit-log thin context wrapper for all admin mutations (§5.12).

  Per §5.12 / §13, every admin mutation writes an `audit_log` row in
  the **same transaction** as the mutation. This module is the
  single write surface for that row; callers (Catalog, Media, CRM,
  Billing — P1-E2.4 / P1-E4 / P1-E6 / P6) compose their own writes
  through `Repo.transact/1` so the audit and the mutation commit
  atomically. The audit hook is **fail-closed**: a failed audit
  write rolls the mutation back.

  ## Usage (the canonical pattern)

      def create_project(attrs, opts \\\\ []) do
        Repo.transact(fn ->
          with {:ok, project} <-
                 %Project{} |> Project.create_changeset(attrs) |> Repo.insert(),
               :ok <- Immo.Audit.log_mutation(
                 actor_user: opts[:actor_user],
                 action: "create",
                 entity: project,
                 diff: Immo.Audit.create_diff(project)
               ) do
            {:ok, project}
          end
        end)
      end

  For updates, the caller captures the **old** state (pre-update)
  and passes both to the diff helper:

      Repo.transact(fn ->
        old = project
        cs = Project.update_changeset(project, attrs, actor_role: opts[:actor_role])

        with {:ok, updated} <- Repo.update(cs),
             :ok <- Immo.Audit.log_mutation(
               actor_user: opts[:actor_user],
               action: "update",
               entity: updated,
               diff: Immo.Audit.update_diff(old, updated, cs)
             ) do
          {:ok, updated}
        end
      end)

  ## Diff shape (§5.12)

  The `diff` jsonb has shape:

      %{
        "before" => %{...},  # old values of changed fields, key → value
        "after"  => %{...},  # new values of changed fields
        "changed" => [...]   # sorted list of changed field names
      }

  For `create` / `delete`, only `after` / `before` is populated
  respectively. The `changed` list is the sorted list of field
  names that differ.

  ## Why a context, not a module-attribute helper

  A common alternative is `Immo.Audit.on_every_mutation/4` macro.
  The context approach is preferred because:
    1. The shape of `diff` is centralized — callers don't reinvent
       it.
    2. The "same transaction" guarantee is explicit (raises
       `OutsideTransactionError` if the caller forgot to wrap).
    3. The query API for the P1-E3.5 viewer lives next to the
       write API; both speak the same types.

  ## Out of scope (P1-E2.4)

    * The viewer UI itself — P1-E3.5.
    * Retention/rotation — not in v1 spec.
    * Asynchronous writes — the spec is explicit that audit must
      be in the same transaction (rolls back with the mutation).
  """

  import Ecto.Query, only: [where: 3, order_by: 2, limit: 2, offset: 2]

  alias Immo.Accounts.User
  alias Immo.AuditLog
  alias Immo.Repo

  @entity_id_keys [:id, :binary_id, :uuid]

  ## Write API

  @doc """
  The single write surface for audit_log. MUST be called inside an
  active `Repo.transact/1` — the audit row is part of the same
  transaction as the mutation; if the mutation rolls back, so does
  the audit.

  ## Arguments

    * `:actor_user` — the `%User{}` who performed the mutation.
      May be `nil` for system-triggered mutations (cron build, webhook).
    * `:action` — short verb (`create`, `update`, `delete`,
      `publish`, `unpublish`, ...).
    * `:entity` — the Ecto struct after the mutation (for `create`)
      OR after the update (for `update`); the entity_type is
      inferred from the struct's `__struct__` and the entity_id from
      its `:id` field.
    * `:diff` — a map with the diff shape described in the moduledoc.
      The `changed` key is required; `before` / `after` are optional
      (omit when the action is `create` — there's no `before`).

  Returns `:ok` on success; `{:error, changeset}` on validation
  failure.

  ## Failure modes

    * `OutsideTransactionError` — caller forgot to wrap the
      mutation in `Repo.transact/1`. The `audit_log` row must commit
      atomically with the mutation; the check is at runtime, not
      compile time, so it surfaces only at the call site.
    * Missing `:id` on the entity — every audit row needs an
      `entity_id`; entities without `:id` (e.g. failed inserts) can't
      be audited (the caller's transaction will roll back via the
      failing insert anyway).
  """
  @spec log_mutation(keyword()) :: :ok | {:error, Ecto.Changeset.t()}
  def log_mutation(opts) do
    if not in_transaction?() do
      raise __MODULE__.OutsideTransactionError,
            "Immo.Audit.log_mutation/1 must be called inside Repo.transact/1. " <>
              "Wrap your mutation in Repo.transact/1 so the audit row " <>
              "and the mutation commit atomically (§5.12)."
    end

    actor_user = Keyword.get(opts, :actor_user)
    action = Keyword.fetch!(opts, :action)
    entity = Keyword.fetch!(opts, :entity)
    diff = Keyword.fetch!(opts, :diff)

    user_id = user_id_for(actor_user)
    entity_type = entity_type_for(entity)
    entity_id = entity_id_for(entity)

    %AuditLog{
      user_id: user_id,
      action: action,
      entity_type: entity_type,
      entity_id: entity_id,
      diff: diff
    }
    |> Repo.insert()
    |> case do
      {:ok, _audit} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  The diff for a `create` action. Only `after` is populated (no
  prior state to diff against).
  """
  @spec create_diff(struct()) :: %{required(String.t()) => term()}
  def create_diff(entity) do
    fields = auditable_fields(entity)

    %{
      "before" => %{},
      "after" => serialize_fields(entity, fields),
      "changed" => Enum.sort(fields)
    }
  end

  @doc """
  The diff for an `update` action. Compares the pre-update struct
  (`old`) against the post-update struct (`new`) and the changeset's
  `changes` (the set of dirty fields). The diff contains ONLY the
  changed fields.

  `changeset.changes` is the authoritative list of dirty fields —
  fields the user actually wrote — so the diff reflects what the
  caller asked for (not the union of `old` vs `new`, which would
  include Ecto-managed fields like `inserted_at` and `updated_at`
  that change on every update).
  """
  @spec update_diff(struct(), struct(), Ecto.Changeset.t()) :: %{
          required(String.t()) => term()
        }
  def update_diff(old, new, changeset) do
    dirty_keys = Map.keys(changeset.changes)

    # Read old/new values by the original atom key first. The
    # comparison phase uses the atom key; the string conversion
    # is only for the final output (jsonb storage).
    old_by_key = Map.new(dirty_keys, fn k -> {k, Map.get(old, k)} end)
    new_by_key = Map.new(dirty_keys, fn k -> {k, Map.get(new, k)} end)

    # A "change" is a key whose value differs between old and new.
    # Ecto reports the `changes` map even when the value didn't
    # actually change (e.g. a no-op update), so we filter to the
    # truly-different ones.
    changed_atoms =
      dirty_keys
      |> Enum.filter(fn k -> old_by_key[k] != new_by_key[k] end)
      |> Enum.sort()

    %{
      "before" => Map.new(changed_atoms, fn k -> {to_string(k), old_by_key[k]} end),
      "after" => Map.new(changed_atoms, fn k -> {to_string(k), new_by_key[k]} end),
      "changed" => Enum.map(changed_atoms, &to_string/1)
    }
  end

  @doc """
  The diff for a `delete` action. Only `before` is populated.
  """
  @spec delete_diff(struct()) :: %{required(String.t()) => term()}
  def delete_diff(entity) do
    fields = auditable_fields(entity)

    %{
      "before" => serialize_fields(entity, fields),
      "after" => %{},
      "changed" => Enum.sort(fields)
    }
  end

  ## Read API (P1-E3.5 viewer)

  @doc """
  List the most recent audit_log rows (newest first). The
  `default_limit` defaults to 50 rows; pass a higher limit for
  the viewer with explicit pagination.

  Optional filters:
    * `:entity_type` — exact match
    * `:entity_id` — exact match
    * `:user_id` — exact match
    * `:action` — exact match
  """
  @spec list_recent(keyword()) :: [AuditLog.t()]
  def list_recent(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    AuditLog
    |> apply_filters(opts)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  List audit_log rows for a specific entity (entity_type + entity_id).
  Useful for the §6.2 "show me all writes that touched this record"
  debug view.
  """
  @spec list_for_entity(String.t(), binary(), keyword()) :: [AuditLog.t()]
  def list_for_entity(entity_type, entity_id, opts \\ []) when is_binary(entity_id) do
    list_recent(Keyword.merge([entity_type: entity_type, entity_id: entity_id], opts))
  end

  @doc """
  List audit_log rows for a specific user. Useful for the §6.2
  audit viewer's "writes by this user" tab.
  """
  @spec list_for_user(integer() | binary(), keyword()) :: [AuditLog.t()]
  def list_for_user(user_id, opts \\ []) do
    list_recent(Keyword.merge([user_id: user_id], opts))
  end

  @doc """
  List audit_log rows for a specific action (e.g. all `publish`
  events). Useful for "what got published in the last 24 h" views.
  """
  @spec list_for_action(String.t(), keyword()) :: [AuditLog.t()]
  def list_for_action(action, opts \\ []) when is_binary(action) do
    list_recent(Keyword.merge([action: action], opts))
  end

  @doc """
  Total count of audit_log rows, optionally filtered the same way
  as `list_recent/1`. The P1-E3.5 viewer uses this to render the
  pagination controls ("showing 50 of 234 results").
  """
  @spec count(keyword()) :: non_neg_integer()
  def count(opts \\ []) do
    AuditLog
    |> apply_filters(opts)
    |> Repo.aggregate(:count, :id)
  end

  ## Errors

  defmodule OutsideTransactionError do
    @moduledoc """
    Raised by `log_mutation/1` when the caller forgot to wrap the
    mutation in `Repo.transact/1`. The error message points the
    caller at the §5.12 atomic-commit requirement.
    """
    defexception message: "Immo.Audit.log_mutation/1 called outside Repo.transact/1"
  end

  ## Helpers

  defp in_transaction? do
    # Ecto.Repo.transact/1 wraps the function in a database
    # transaction. The `Repo.in_transaction?/1` predicate returns
    # true when the current process is inside one.
    Repo.in_transaction?()
  rescue
    _ -> false
  end

  defp user_id_for(nil), do: nil
  defp user_id_for(%User{id: id}) when is_integer(id) or is_binary(id), do: id

  defp entity_type_for(%struct_module{} = _entity) do
    struct_module
    |> Module.split()
    |> List.last()
    |> to_string()
  end

  defp entity_id_for(entity) do
    Enum.find_value(@entity_id_keys, fn key ->
      case Map.get(entity, key) do
        id when is_integer(id) or is_binary(id) -> id
        _ -> nil
      end
    end)
  end

  # The list of fields to include in the diff. Filters out Ecto
  # internals (__meta__, __struct__, associations) and timestamp
  # fields (the audit row itself records when the change happened;
  # the diff shouldn't say "updated_at changed from X to Y" because
  # that's a write-time artifact, not a user-meaningful change).
  #
  # We also drop association fields: a loaded association is
  # represented in the diff as its `:id` (via `serialize_fields`)
  # but we don't want the field name appearing as a "changed"
  # column when the user never edited it.
  defp auditable_fields(entity) do
    associations = entity_associations(entity)

    entity
    |> Map.keys()
    |> Enum.reject(&internal_field?(&1, associations))
  end

  defp entity_associations(entity) do
    do_associations(entity)
  rescue
    _ -> []
  end

  defp do_associations(%_{} = struct), do: struct.__struct__.__schema__(:associations)
  defp do_associations(_), do: []

  defp internal_field?(:__struct__, _), do: true
  defp internal_field?(:__meta__, _), do: true
  defp internal_field?(:inserted_at, _), do: true
  defp internal_field?(:updated_at, _), do: true
  defp internal_field?(:id, _), do: true
  defp internal_field?(:password, _), do: true
  defp internal_field?(:hashed_password, _), do: true

  defp internal_field?(field, associations) do
    field in associations
  end

  # Convert an Ecto struct's fields to a plain map for jsonb
  # storage. We don't include Ecto-managed associations in the
  # diff — the audit row is meant to capture the columnar fields
  # the user wrote, not the joined data. A loaded association like
  # `%PropertyType{...}` would also crash the jsonb encoder.
  #
  # The diff map's value for an association is its `:id` (or
  # `nil` for `NotLoaded`); the full struct is reconstructable
  # via the foreign key on the referencing table.
  defp serialize_fields(entity, fields) do
    Map.new(fields, fn field ->
      value = Map.get(entity, field)
      {to_string(field), auditable_value(value)}
    end)
  end

  defp auditable_value(%Ecto.Association.NotLoaded{}), do: nil

  defp auditable_value(%_{} = value) do
    # A struct (loaded association, embedded, or another table's
    # row) — represent as its `:id` so the jsonb stays compact
    # and the viewer can pivot to the referenced row by id.
    case Map.get(value, :id) do
      id when is_integer(id) or is_binary(id) -> id
      _ -> nil
    end
  end

  defp auditable_value(value), do: value

  defp apply_filters(query, opts) do
    Enum.reduce(opts, query, fn
      {:entity_type, type}, q when is_binary(type) ->
        where(q, [a], a.entity_type == ^type)

      {:entity_id, id}, q when is_binary(id) ->
        where(q, [a], a.entity_id == ^id)

      {:user_id, id}, q when is_integer(id) or is_binary(id) ->
        where(q, [a], a.user_id == ^id)

      {:action, action}, q when is_binary(action) ->
        where(q, [a], a.action == ^action)

      _, q ->
        q
    end)
  end
end
