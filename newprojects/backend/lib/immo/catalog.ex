defmodule Immo.Catalog do
  @moduledoc """
  Catalog context — the cross-cutting module shipped with P1-E1.2
  that defines the developer-user tenant-scoping mechanism. The real
  Catalog CRUD (projects, listings, property types, custom fields) is
  owned by P1-E2; the entity-level `list_*` / `get_*` / `create_*`
  functions come from that epic.

  ## Why this module exists now

  §5.8 / P1-E1.2 require that **every catalog query for a
  `developer_user` be filtered to `where entity.developer_id = ^
  scope.tenant_id`**. The on_mount hook only blocks the page render;
  the query is the actual defense against cross-tenant reads. Centralising
  the filter in one place — `Immo.Catalog.scoped_query/2` — means
  P1-E2's entity listers cannot forget to apply it: they call into this
  module, and this module either applies the tenant filter or returns
  the query unchanged for staff.

  ## Scoping rules (P1-E1.2 / §5.8)

    * **Staff roles** (`admin`, `manager`, `editor`): queries pass through
      unchanged. Admins/managers see the whole catalog; editors see the
      whole catalog. The §6.2 staff hierarchy doesn't change query
      filtering — it only changes which LiveViews you can mount.

    * **`developer_user`**: queries get an extra
      `where: entity.developer_id == ^scope.tenant_id`. There is no
      exception, no admin-override, no "bypass for debugging" — the
      developer_id on the entity is the only thing that decides what
      they see. Cross-tenant reads and writes are denied by the query
      itself, not by the UI.

    * **Anonymous** (`nil` scope): the public read path; the on_mount
      hook should not have let the call through, but if it does, the
      query helper returns the unfiltered query. The on_mount + plug are
      the only safe defaults; do not let unauthenticated callers reach
      catalog queries that are meant for `developer_user`.

  ## Use (forward-looking, P1-E2)

      def list_projects(scope, opts \\\\ []) do
        Project
        |> Immo.Catalog.scoped_query(scope)
        |> ...
      end

  The `scoped_query/2` takes a queryable (a schema module, an existing
  query, or anything `Ecto.Queryable` accepts) plus a scope. The schema
  is expected to expose a `developer_id` field — the function introspects
  the schema's `__schema__(:fields)` to confirm `developer_id` is present,
  and raises at runtime if it isn't. This catches at the dev-box level
  the case where a P1-E2 list-er forgets to add a `developer_id` to a
  new entity: the call site crashes the first time it's exercised, not
  silently leaks the wrong rows.
  """

  import Ecto.Query, only: [where: 3]

  alias Immo.Accounts.Scope

  @doc """
  Apply tenant scoping to a queryable. See the moduledoc for the rules.

  ## Arguments

    * `queryable` — an Ecto queryable (a schema module, `%Ecto.Query{}`,
      or any value `Ecto.Queryable` accepts).
    * `scope` — an `Immo.Accounts.Scope` (or `nil` for unauthenticated).

  ## Returns

    The original queryable, with an extra `WHERE developer_id = ^
  scope.tenant_id` clause appended for `developer_user` scopes, and
  unchanged for staff scopes (and `nil`).

  ## Raises

    `ArgumentError` if the queryable's underlying schema does not
  declare a `developer_id` field. This is intentional: a missing
  `developer_id` would silently let a `developer_user` see all rows
  through the `scoped_query/2` filter (the WHERE clause would compare
  to a column that doesn't exist or, worse, no-op if Ecto silently
  ignores it). The fail-fast check is a §5.8 safety net.
  """
  @spec scoped_query(Ecto.Queryable.t(), Scope.t() | nil) :: Ecto.Queryable.t()
  def scoped_query(queryable, %Scope{role: :developer_user, developer_id: tenant_id})
      when is_binary(tenant_id) do
    require_tenant_scoped_schema!(queryable)
    where(queryable, [...], developer_id: ^tenant_id)
  end

  def scoped_query(queryable, %Scope{}), do: queryable

  def scoped_query(queryable, nil), do: queryable

  # Best-effort: an Ecto schema is a module, and we can ask it for its
  # fields. For arbitrary queries we resolve the source via Ecto's
  # `first/1` (the only safe call against a query without forcing a DB
  # round-trip is to inspect its `from` source).
  defp require_tenant_scoped_schema!(queryable) do
    schema = queryable_schema(queryable)

    if schema && not schema_has_developer_id?(schema) do
      raise ArgumentError,
            "Immo.Catalog.scoped_query/2 called on #{inspect(schema)}, which " <>
              "does not declare a `:developer_id` field. Developer-user " <>
              "tenant scoping (§5.8) is impossible without it. Add " <>
              "`field :developer_id, :binary_id` (or the appropriate FK " <>
              "type) to the schema, or pass the query through a wrapper " <>
              "that joins a related table that does have one."
    end
  end

  defp queryable_schema(queryable) do
    case queryable do
      mod when is_atom(mod) ->
        mod

      %Ecto.Query{from: %{source: {_alias, mod}}} when is_atom(mod) ->
        mod

      _ ->
        nil
    end
  end

  defp schema_has_developer_id?(schema) do
    function_exported?(schema, :__schema__, 1) and
      :developer_id in schema.__schema__(:fields)
  end
end
