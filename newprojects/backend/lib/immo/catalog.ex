defmodule Immo.Catalog do
  @moduledoc """
  Catalog context — the write-side surface for all §6.1 Catalog-owned
  entities: developers, projects, listings, property_types,
  custom_fields, and the `redirects` side effect of slug changes.

  ## Public API

  For every owned entity, the context exposes:

    * `create_<entity>/2` — wraps `create_changeset/2` and inserts.
    * `update_<entity>/3` — wraps `update_changeset/3` (which
      enforces §3.8 slug immutability) and updates; on a slug
      change, the caller is expected to have wrapped the call in
      `record_slug_redirect/4` so the redirects row is written
      transactionally.
    * `delete_<entity>/1` — hard delete.
    * `publish_<entity>/2` — sets `published_at = now`. The
      `Catalog.published/1` predicate (P1-E2.3) decides whether the
      row is **effectively** published (gated by subscription, etc.).
    * `unpublish_<entity>/1` — clears `published_at`.

  Plus the tenant-scoping helper `scoped_query/2` from P1-E1.2.

  Every mutation writes an `audit_log` row via `Immo.Audit.log_mutation/1`
  in the **same transaction** as the mutation. Pass `:actor_user` in
  the `opts` keyword list to record who performed the change
  (§5.12). Rollback of the mutation rolls the audit back too — the
  spec is explicit about atomic commit.

  ## §5.13 publish predicate (P1-E2.3)

  `Catalog.published/1` is the single composable definition of
  "published" for the system. Per §5.13:

      published_at IS NOT NULL
      AND published_at <= now()
      AND (for projects/listings only) the owning developer has a
          subscription with status IN ('active', 'trialing') when
          BILLING_ENFORCED is on.

  Developers themselves are NOT billing-gated (§5.13). The predicate
  is composable — callers add their own `where`/`order_by` clauses
  on top. Callers MUST compose it; re-implementing the predicate
  elsewhere is the §5.13 anti-pattern.

  ## §3.8 slug immutability

  `update_<entity>/3` accepts an `:actor_role` option. When the
  actor is `:admin`, the slug is editable even after the entity has
  been published at least once. For any other role, the slug is
  locked. A permitted slug change does NOT mint the redirects row
  automatically — the caller does it via
  `record_slug_redirect/4` inside the same `Repo.transact/1` block
  (so the redirects row and the slug change commit atomically).

  ## §5.8 tenant scoping

  `scoped_query/2` from P1-E1.2 is the only place the developer_user
  tenant filter lives. The CRUD functions accept a `%Scope{}` and
  apply the filter at the query level. Staff roles get unfiltered
  queries.

  ## Out of scope (P1-E2.2 / P1-E2.3 / P1-E2.4)

    * The `audit_log` viewer UI — P1-E3.5 (the read API is in
      `Immo.Audit.list_recent/1` etc., ready for the viewer).
    * KV dirty-marking on publish/unpublish/slug change (P4).
    * The `Immo.Edge.Paths` single-path authority for old/new path
      strings (P1-E5.2). For P1-E2.2, the caller passes
      `old_path`/`new_path` strings directly.
  """

  import Ecto.Query, only: [where: 3, order_by: 2, limit: 2]

  alias Immo.Accounts.Scope
  alias Immo.Audit
  alias Immo.Repo

  alias Immo.Catalog.{
    CustomField,
    Developer,
    Listing,
    Project,
    PropertyType,
    Redirect
  }

  @doc """
  Whether the §5.13 billing gate is active. Read at runtime from
  `:immo, :billing_enforced` (default `false` per D13 launch posture;
  the dev environment sets it to `true` so the §15.1 matrix tests
  exercise the gated path; tests that need the other branch flip the
  runtime config via `Application.put_env` per test).
  """
  @spec billing_enforced?() :: boolean()
  def billing_enforced?, do: Application.get_env(:immo, :billing_enforced, false)

  ## §5.13 publish predicate (P1-E2.3)

  @doc """
  The single composable definition of "published" for the system.

  Accepts a queryable (a schema module `Developer | Project | Listing`,
  or an existing `%Ecto.Query{}` whose `from` source is one of
  those schemas). Returns a query that callers compose with their own
  `where` / `order_by` / `preload` clauses — this is the
  grep-able single definition per §5.13.

  Per §5.13:

      published_at IS NOT NULL
      AND published_at <= now()
      AND (for projects/listings only) the owning developer has a
          subscription with status IN ('active', 'trialing') when
          BILLING_ENFORCED is on.

  Developers themselves are NOT billing-gated. When `BILLING_ENFORCED`
  is off, the gate is inert and any past-published row is
  "published" (D13 — launch posture until the first paying customer
  flips the flag).
  """
  @spec published(Ecto.Queryable.t()) :: Ecto.Queryable.t()
  def published(queryable) when is_atom(queryable) do
    do_published(queryable)
  end

  @supported_publish_sources [Developer, Project, Listing]

  def published(%Ecto.Query{} = query) do
    source = queryable_schema(query)

    case source do
      s when s in @supported_publish_sources and s == Developer ->
        query
        |> where_published_at_clause(:developer)
        |> apply_developer_billing_gate()

      s when s in @supported_publish_sources and s == Project ->
        query
        |> where_published_at_clause(:project)
        |> apply_project_billing_gate()

      s when s in @supported_publish_sources and s == Listing ->
        query
        |> where_published_at_clause(:listing)
        |> apply_listing_billing_gate()

      _ ->
        raise ArgumentError,
              "Catalog.published/1 only supports Developer, Project, and Listing queries. " <>
                "Got query with unknown source."
    end
  end

  defp do_published(Developer) do
    Developer
    |> where_published_at_clause(:developer)
    |> apply_developer_billing_gate()
  end

  defp do_published(Project) do
    Project
    |> where_published_at_clause(:project)
    |> apply_project_billing_gate()
  end

  defp do_published(Listing) do
    Listing
    |> where_published_at_clause(:listing)
    |> apply_listing_billing_gate()
  end

  defp where_published_at_clause(query, source) do
    case source do
      :developer ->
        where(query, [d], not is_nil(d.published_at) and d.published_at <= ^now_unix())

      :project ->
        where(query, [p], not is_nil(p.published_at) and p.published_at <= ^now_unix())

      :listing ->
        where(query, [l], not is_nil(l.published_at) and l.published_at <= ^now_unix())
    end
  end

  defp apply_developer_billing_gate(query), do: query

  defp apply_project_billing_gate(query) do
    if billing_enforced?() do
      where(
        query,
        [p],
        fragment(
          "EXISTS (SELECT 1 FROM subscriptions s WHERE s.developer_id = ? AND s.status IN ('active', 'trialing'))",
          p.developer_id
        )
      )
    else
      query
    end
  end

  defp apply_listing_billing_gate(query) do
    if billing_enforced?() do
      where(
        query,
        [l],
        fragment(
          "EXISTS (SELECT 1 FROM subscriptions s JOIN projects p ON p.id = ? WHERE s.developer_id = p.developer_id AND s.status IN ('active', 'trialing'))",
          l.project_id
        )
      )
    else
      query
    end
  end

  defp now_unix, do: DateTime.utc_now(:second)

  ## Tenant scoping (P1-E1.2)

  @doc """
  Apply tenant scoping to a queryable. See the moduledoc for the rules.
  """
  @spec scoped_query(Ecto.Queryable.t(), Scope.t() | nil) :: Ecto.Queryable.t()
  def scoped_query(queryable, %Scope{role: :developer_user, developer_id: tenant_id})
      when is_binary(tenant_id) do
    require_tenant_scoped_schema!(queryable)
    where(queryable, [...], developer_id: ^tenant_id)
  end

  def scoped_query(queryable, %Scope{}), do: queryable

  def scoped_query(queryable, nil), do: queryable

  defp require_tenant_scoped_schema!(queryable) do
    schema = queryable_schema(queryable)

    if schema && not schema_has_developer_id?(schema) do
      raise ArgumentError,
            "Immo.Catalog.scoped_query/2 called on #{inspect(schema)}, which " <>
              "does not declare a `:developer_id` field."
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

  ## Developers

  @doc "Get a developer by id (raises if not found)."
  def get_developer!(id), do: Repo.get!(Developer, id)

  @doc "Get a developer by slug. Returns nil if not found."
  def get_developer_by_slug(slug) when is_binary(slug) do
    Repo.get_by(Developer, slug: slug)
  end

  @doc "List developers, scoped to a `%Scope{}` for §5.8 tenant isolation."
  def list_developers(scope \\ nil) do
    Developer
    |> scoped_query(scope)
    |> order_by(asc: :name)
    |> Repo.all()
  end

  @doc """
  Create a developer (draft; `published_at` is nil). Writes an
  `audit_log` row in the same transaction.
  """
  def create_developer(attrs, opts \\ []) do
    Repo.transact(fn ->
      with {:ok, developer} <-
             %Developer{} |> Developer.create_changeset(attrs) |> Repo.insert(),
           :ok <-
             Audit.log_mutation(
               actor_user: opts[:actor_user],
               action: "create",
               entity: developer,
               diff: Audit.create_diff(developer)
             ) do
        {:ok, developer}
      end
    end)
  end

  @doc """
  Update a developer. Pass `:actor_role` in `opts` to enable the
  §3.8 admin override. Writes an `audit_log` row in the same
  transaction with the field-level diff (§5.12).
  """
  def update_developer(developer, attrs, opts \\ []) do
    actor_role = Keyword.get(opts, :actor_role)
    old = developer

    Repo.transact(fn ->
      cs = Developer.update_changeset(developer, attrs, actor_role: actor_role)

      with {:ok, updated} <- Repo.update(cs),
           :ok <-
             Audit.log_mutation(
               actor_user: opts[:actor_user],
               action: "update",
               entity: updated,
               diff: Audit.update_diff(old, updated, cs)
             ) do
        {:ok, updated}
      end
    end)
  end

  @doc "Publish a developer (sets `published_at` to now). Idempotent."
  def publish_developer(developer, opts \\ []) do
    if developer.published_at do
      {:ok, developer}
    else
      Repo.transact(fn ->
        updated = change_published_at(developer, DateTime.utc_now(:second)) |> Repo.update!()

        Audit.log_mutation(
          actor_user: opts[:actor_user],
          action: "publish",
          entity: updated,
          diff:
            Audit.update_diff(
              developer,
              updated,
              Ecto.Changeset.change(developer, %{published_at: updated.published_at})
            )
        )

        {:ok, updated}
      end)
    end
  end

  @doc "Unpublish a developer (clears `published_at`). Idempotent."
  def unpublish_developer(developer, opts \\ []) do
    if is_nil(developer.published_at) do
      {:ok, developer}
    else
      Repo.transact(fn ->
        updated = change_published_at(developer, nil) |> Repo.update!()

        Audit.log_mutation(
          actor_user: opts[:actor_user],
          action: "unpublish",
          entity: updated,
          diff:
            Audit.update_diff(
              developer,
              updated,
              Ecto.Changeset.change(developer, %{published_at: nil})
            )
        )

        {:ok, updated}
      end)
    end
  end

  @doc """
  Delete a developer. The DB-level FK on `users.developer_id` will
  reject if any user is bound. Writes an `audit_log` row.
  """
  def delete_developer(developer, opts \\ []) do
    Repo.transact(fn ->
      with {:ok, _} <- Repo.delete(developer),
           :ok <-
             Audit.log_mutation(
               actor_user: opts[:actor_user],
               action: "delete",
               entity: developer,
               diff: Audit.delete_diff(developer)
             ) do
        {:ok, developer}
      end
    end)
  end

  ## Projects

  @doc "Get a project by id (raises if not found)."
  def get_project!(id), do: Repo.get!(Project, id)

  @doc "Get a project by slug (citext). Returns nil if not found."
  def get_project_by_slug(slug) when is_binary(slug) do
    Repo.get_by(Project, slug: slug)
  end

  @doc "List projects, scoped to a `%Scope{}` for §5.8 tenant isolation."
  def list_projects(scope \\ nil) do
    Project
    |> scoped_query(scope)
    |> order_by(asc: :title)
    |> Repo.all()
  end

  def create_project(attrs, opts \\ []) do
    Repo.transact(fn ->
      with {:ok, project} <-
             %Project{} |> Project.create_changeset(attrs) |> Repo.insert(),
           :ok <-
             Audit.log_mutation(
               actor_user: opts[:actor_user],
               action: "create",
               entity: project,
               diff: Audit.create_diff(project)
             ) do
        {:ok, project}
      end
    end)
  end

  def update_project(project, attrs, opts \\ []) do
    actor_role = Keyword.get(opts, :actor_role)
    old = project

    Repo.transact(fn ->
      cs = Project.update_changeset(project, attrs, actor_role: actor_role)

      with {:ok, updated} <- Repo.update(cs),
           :ok <-
             Audit.log_mutation(
               actor_user: opts[:actor_user],
               action: "update",
               entity: updated,
               diff: Audit.update_diff(old, updated, cs)
             ) do
        {:ok, updated}
      end
    end)
  end

  def publish_project(project, opts \\ []) do
    if project.published_at do
      {:ok, project}
    else
      Repo.transact(fn ->
        updated = change_published_at(project, DateTime.utc_now(:second)) |> Repo.update!()

        Audit.log_mutation(
          actor_user: opts[:actor_user],
          action: "publish",
          entity: updated,
          diff:
            Audit.update_diff(
              project,
              updated,
              Ecto.Changeset.change(project, %{published_at: updated.published_at})
            )
        )

        {:ok, updated}
      end)
    end
  end

  def unpublish_project(project, opts \\ []) do
    if is_nil(project.published_at) do
      {:ok, project}
    else
      Repo.transact(fn ->
        updated = change_published_at(project, nil) |> Repo.update!()

        Audit.log_mutation(
          actor_user: opts[:actor_user],
          action: "unpublish",
          entity: updated,
          diff:
            Audit.update_diff(
              project,
              updated,
              Ecto.Changeset.change(project, %{published_at: nil})
            )
        )

        {:ok, updated}
      end)
    end
  end

  def delete_project(project, opts \\ []) do
    Repo.transact(fn ->
      with {:ok, _} <- Repo.delete(project),
           :ok <-
             Audit.log_mutation(
               actor_user: opts[:actor_user],
               action: "delete",
               entity: project,
               diff: Audit.delete_diff(project)
             ) do
        {:ok, project}
      end
    end)
  end

  ## Listings

  @doc "Get a listing by id (raises if not found)."
  def get_listing!(id), do: Repo.get!(Listing, id)

  @doc "Get a listing by property_type + slug (per §5.4 uniqueness). Returns nil if not found."
  def get_listing_by_slug(property_type_id, slug)
      when is_binary(property_type_id) and is_binary(slug) do
    Repo.get_by(Listing, property_type_id: property_type_id, slug: slug)
  end

  @doc "List listings, scoped to a `%Scope{}` for §5.8 tenant isolation."
  def list_listings(scope \\ nil) do
    Listing
    |> scoped_query(scope)
    |> order_by(asc: :title)
    |> Repo.all()
  end

  def create_listing(attrs, opts \\ []) do
    Repo.transact(fn ->
      with {:ok, listing} <-
             %Listing{}
             |> preload_associations(attrs)
             |> Listing.create_changeset(attrs)
             |> Repo.insert(),
           :ok <-
             Audit.log_mutation(
               actor_user: opts[:actor_user],
               action: "create",
               entity: listing,
               diff: Audit.create_diff(listing)
             ) do
        {:ok, listing}
      end
    end)
  end

  def update_listing(listing, attrs, opts \\ []) do
    actor_role = Keyword.get(opts, :actor_role)
    old = listing

    Repo.transact(fn ->
      cs =
        listing
        |> preload_associations(attrs)
        |> Listing.update_changeset(attrs, actor_role: actor_role)

      with {:ok, updated} <- Repo.update(cs),
           :ok <-
             Audit.log_mutation(
               actor_user: opts[:actor_user],
               action: "update",
               entity: updated,
               diff: Audit.update_diff(old, updated, cs)
             ) do
        {:ok, updated}
      end
    end)
  end

  def publish_listing(listing, opts \\ []) do
    if listing.published_at do
      {:ok, listing}
    else
      Repo.transact(fn ->
        updated = change_published_at(listing, DateTime.utc_now(:second)) |> Repo.update!()

        Audit.log_mutation(
          actor_user: opts[:actor_user],
          action: "publish",
          entity: updated,
          diff:
            Audit.update_diff(
              listing,
              updated,
              Ecto.Changeset.change(listing, %{published_at: updated.published_at})
            )
        )

        {:ok, updated}
      end)
    end
  end

  def unpublish_listing(listing, opts \\ []) do
    if is_nil(listing.published_at) do
      {:ok, listing}
    else
      Repo.transact(fn ->
        updated = change_published_at(listing, nil) |> Repo.update!()

        Audit.log_mutation(
          actor_user: opts[:actor_user],
          action: "unpublish",
          entity: updated,
          diff:
            Audit.update_diff(
              listing,
              updated,
              Ecto.Changeset.change(listing, %{published_at: nil})
            )
        )

        {:ok, updated}
      end)
    end
  end

  def delete_listing(listing, opts \\ []) do
    Repo.transact(fn ->
      with {:ok, _} <- Repo.delete(listing),
           :ok <-
             Audit.log_mutation(
               actor_user: opts[:actor_user],
               action: "delete",
               entity: listing,
               diff: Audit.delete_diff(listing)
             ) do
        {:ok, listing}
      end
    end)
  end

  ## Property types

  @doc "Get a property type by id."
  def get_property_type!(id), do: Repo.get!(PropertyType, id)

  @doc "Get a property type by key (`apartment`, `land`, ...)."
  def get_property_type_by_key(key) when is_binary(key) do
    Repo.get_by(PropertyType, key: key)
  end

  @doc "List all property types, ordered by `position`."
  def list_property_types do
    PropertyType
    |> order_by(asc: :position, asc: :key)
    |> Repo.all()
  end

  def create_property_type(attrs, opts \\ []) do
    Repo.transact(fn ->
      with {:ok, property_type} <-
             %PropertyType{} |> PropertyType.create_changeset(attrs) |> Repo.insert(),
           :ok <-
             Audit.log_mutation(
               actor_user: opts[:actor_user],
               action: "create",
               entity: property_type,
               diff: Audit.create_diff(property_type)
             ) do
        {:ok, property_type}
      end
    end)
  end

  def update_property_type(property_type, attrs, opts \\ []) do
    old = property_type

    Repo.transact(fn ->
      cs = PropertyType.update_changeset(property_type, attrs)

      with {:ok, updated} <- Repo.update(cs),
           :ok <-
             Audit.log_mutation(
               actor_user: opts[:actor_user],
               action: "update",
               entity: updated,
               diff: Audit.update_diff(old, updated, cs)
             ) do
        {:ok, updated}
      end
    end)
  end

  def delete_property_type(property_type, opts \\ []) do
    Repo.transact(fn ->
      with {:ok, _} <- Repo.delete(property_type),
           :ok <-
             Audit.log_mutation(
               actor_user: opts[:actor_user],
               action: "delete",
               entity: property_type,
               diff: Audit.delete_diff(property_type)
             ) do
        {:ok, property_type}
      end
    end)
  end

  ## Custom fields (§5.5 / R9)

  @doc "List custom fields for a property type, ordered by position."
  def list_custom_fields(property_type_id) when is_binary(property_type_id) do
    CustomField
    |> where([cf], cf.property_type_id == ^property_type_id)
    |> order_by(asc: :position, asc: :key)
    |> Repo.all()
  end

  def create_custom_field(attrs, opts \\ []) do
    Repo.transact(fn ->
      with {:ok, custom_field} <-
             %CustomField{} |> CustomField.create_changeset(attrs) |> Repo.insert(),
           :ok <-
             Audit.log_mutation(
               actor_user: opts[:actor_user],
               action: "create",
               entity: custom_field,
               diff: Audit.create_diff(custom_field)
             ) do
        {:ok, custom_field}
      end
    end)
  end

  def update_custom_field(custom_field, attrs, opts \\ []) do
    old = custom_field

    Repo.transact(fn ->
      cs = CustomField.update_changeset(custom_field, attrs)

      with {:ok, updated} <- Repo.update(cs),
           :ok <-
             Audit.log_mutation(
               actor_user: opts[:actor_user],
               action: "update",
               entity: updated,
               diff: Audit.update_diff(old, updated, cs)
             ) do
        {:ok, updated}
      end
    end)
  end

  def delete_custom_field(custom_field, opts \\ []) do
    Repo.transact(fn ->
      with {:ok, _} <- Repo.delete(custom_field),
           :ok <-
             Audit.log_mutation(
               actor_user: opts[:actor_user],
               action: "delete",
               entity: custom_field,
               diff: Audit.delete_diff(custom_field)
             ) do
        {:ok, custom_field}
      end
    end)
  end

  ## Slug-change side effect (§3.8)

  @doc """
  Write a `redirects` row. The caller is expected to compose this
  with `update_<entity>/3` via `Repo.transact/1` so the slug change
  and the redirects row commit atomically.

  Returns `{:ok, redirect}` or `{:error, changeset}`.
  """
  def record_slug_redirect(entity, old_slug, new_slug, opts \\ [])
      when is_binary(old_slug) and is_binary(new_slug) do
    reason = Keyword.get(opts, :reason)
    old_path = old_slug_to_path(entity, old_slug)
    new_path = old_slug_to_path(entity, new_slug)

    %Redirect{}
    |> Redirect.create_changeset(%{
      old_path: old_path,
      new_path: new_path,
      http_status: 301,
      reason: reason
    })
    |> Repo.insert()
  end

  defp old_slug_to_path(_entity, slug), do: "/" <> slug

  ## Helpers

  defp change_published_at(record, %DateTime{} = dt) do
    Ecto.Changeset.change(record, %{published_at: dt})
  end

  defp change_published_at(record, nil) do
    Ecto.Changeset.change(record, %{published_at: nil})
  end

  # Listing changesets depend on `project` (for §5.4 location
  # inheritance) and `property_type` (for §5.4 attributes validation).
  # This helper loads both from the attrs' foreign-key columns when
  # present, falling back to `Repo.preload` of the in-memory
  # association when the caller didn't pass a new id.
  defp preload_associations(listing, attrs) do
    listing
    |> preload_assoc(:project, attrs[:project_id] || attrs["project_id"])
    |> preload_assoc(:property_type, attrs[:property_type_id] || attrs["property_type_id"])
  end

  defp preload_assoc(listing, :project, id) when is_binary(id) do
    Map.put(listing, :project, Repo.get!(Project, id))
  end

  defp preload_assoc(listing, :property_type, id) when is_binary(id) do
    record = Repo.get!(PropertyType, id) |> Repo.preload(:custom_fields)
    Map.put(listing, :property_type, record)
  end

  defp preload_assoc(listing, :project, _id) do
    Repo.preload(listing, :project)
  end

  defp preload_assoc(listing, :property_type, _id) do
    Repo.preload(listing, property_type: [:custom_fields])
  end

  ## §6.3 — Published list endpoints for the build tier
  ## (`/api/v1/projects`, `/listings`, `/developers`,
  ## `/property_types`). Composes `published/1` and adds
  ## cursor (`WHERE id > ^cursor`) + `since` (ISO-8601 on
  ## `updated_at`) + `limit` (clamped at the caller). P1-E5.2.

  @doc """
  List published developers, paginated by cursor over `id`,
  filtered by `since` on `updated_at`. Composes `published/1`
  so unpublished, future-published, and billing-gated records
  are absent (§5.13).

  Options:
    * `:limit`     — page size; caller is responsible for clamping
    * `:cursor_id` — the id of the last record from the previous
      page; nil = first page
    * `:since`     — `DateTime.t()`; nil = no time filter
  """
  @spec list_published_developers(keyword()) :: [Developer.t()]
  def list_published_developers(opts \\ []) do
    Developer
    |> published()
    |> apply_list_filters(opts)
    |> Repo.all()
  end

  @doc """
  List published projects, paginated by cursor over `id`,
  filtered by `since` on `updated_at`. Composes `published/1`.
  """
  @spec list_published_projects(keyword()) :: [Project.t()]
  def list_published_projects(opts \\ []) do
    Project
    |> published()
    |> apply_list_filters(opts)
    |> Repo.all()
  end

  @doc """
  List published listings, paginated by cursor over `id`,
  filtered by `since` on `updated_at`. Composes `published/1`.
  """
  @spec list_published_listings(keyword()) :: [Listing.t()]
  def list_published_listings(opts \\ []) do
    Listing
    |> published()
    |> apply_list_filters(opts)
    |> Repo.all()
  end

  @doc """
  List all property types.

  `PropertyType` has no `published_at` field — once a row is
  created it is considered "published" (the public URL
  namespace is taken from `key` / `url_segment`). The §6.3
  spec calls for adding a per-type visibility gate in a
  later phase; for now every row is exposed to the search
  island's filter sidebar. The list is shaped (cursor +
  limit) by `apply_list_filters_no_publish/2` so the API
  contract still composes with the same pagination
  machinery as the other build-tier endpoints.
  """
  @spec list_published_property_types(keyword()) :: [PropertyType.t()]
  def list_published_property_types(opts \\ []) do
    PropertyType
    |> apply_list_filters_no_publish(opts)
    |> Repo.all()
  end

  @doc """
  List active redirects (where `http_status` is non-nil and
  `old_path` is non-empty). Used by `/api/v1/redirects` for
  the build-time `redirects.json` (per §3.8 / §6.3).
  """
  @spec list_active_redirects() :: [Redirect.t()]
  def list_active_redirects do
    Redirect
    |> where([r], not is_nil(r.http_status))
    |> where([r], r.old_path != "")
    |> order_by(asc: :old_path)
    |> Repo.all()
  end

  @doc """
  Get a single **published** project by slug. Returns `nil` when:
    * the slug does not exist, OR
    * the slug exists but the project is unpublished / future-published /
      billing-gated (per §5.13 — never leak the existence of a draft).

  Composes `published/1` so the §5.13 predicate (incl. the billing
  gate) is the single source of truth. Callers (the §6.3 render
  endpoints) treat `nil` as a 404 — no distinction between
  "doesn't exist" and "unpublished", to avoid leaking the draft
  list to authenticated render consumers.
  """
  @spec get_published_project_by_slug(String.t()) :: Project.t() | nil
  def get_published_project_by_slug(slug) when is_binary(slug) do
    Project
    |> published()
    |> Repo.get_by(slug: slug)
  end

  @doc """
  Get a single **published** developer by slug. Returns `nil` for
  missing or non-published rows (per §5.13). Developers are not
  billing-gated, so the predicate reduces to "published_at is in
  the past".
  """
  @spec get_published_developer_by_slug(String.t()) :: Developer.t() | nil
  def get_published_developer_by_slug(slug) when is_binary(slug) do
    Developer
    |> published()
    |> Repo.get_by(slug: slug)
  end

  @doc """
  Get a single **published** listing by `(property_type_id, slug)`.
  Per §5.4, a listing's slug is unique within its property_type
  namespace; the property_type segment is part of the public URL
  (`/appartements/casablanca/...` vs `/terrains/casablanca/...`).

  Returns `nil` for missing or non-published rows. Same 404-or-200
  treatment as the developer/project lookups.
  """
  @spec get_published_listing(String.t(), String.t()) :: Listing.t() | nil
  def get_published_listing(property_type_id, slug)
      when is_binary(property_type_id) and is_binary(slug) do
    Listing
    |> published()
    |> Repo.get_by(property_type_id: property_type_id, slug: slug)
  end

  @doc """
  Get a property type by `key` (e.g. `"apartment"`, `"land"`).
  Used by the §6.3 render endpoints to resolve the
  `:property_type` in the URL → `property_type_id` for the
  listing slug lookup.
  """
  # PropertyType has no `published_at` field — once created, a
  # property type is considered "published" (the public URL
  # namespace). The P1-E5.2 spec calls for adding the gate in a
  # later phase; for now this resolves the type_key unconditionally.
  @spec get_published_property_type_by_key(String.t()) :: PropertyType.t() | nil
  def get_published_property_type_by_key(key) when is_binary(key) do
    Repo.get_by(PropertyType, key: key)
  end

  @doc """
  Order a query by `field` descending, with a `limit`. Used by
  the §6.3 render endpoints' "recent" summary embeds (e.g. the
  most-recently-updated published listings for a project).
  Composes on top of an existing query — callers stack the
  `published/1` predicate first.
  """
  @spec order_by_recent(Ecto.Queryable.t(), atom(), pos_integer()) :: Ecto.Queryable.t()
  def order_by_recent(queryable, field, limit)
      when is_atom(field) and is_integer(limit) and limit > 0 do
    queryable
    |> Ecto.Query.order_by(desc: ^field)
    |> Ecto.Query.limit(^limit)
  end

  @doc """
  Resolve a public path to a published entity's `updated_at` for
  the §6.3 / §3.5 `/internal/freshness?path=` endpoint. The
  endpoint is the documented KV-alternative when the §3.5 KV
  freshness gate lags behind a publish.

  Returns `{:ok, updated_at}` for a published path, `nil` for
  missing / unpublished paths. Callers 404 on `nil` so the
  freshness check matches the render lookups (no leak of
  draft paths).

  Path shapes (per §7.1):
    * `/promoteurs/{slug}`        → developer
    * `/projets/{city}/{slug}`    → project
    * `/{type_segment}/{city}/{slug}` → listing

  Anything else (root, type index, etc.) returns `nil`.
  """
  @spec freshness_for_path(String.t()) :: {:ok, DateTime.t()} | nil
  def freshness_for_path(path) when is_binary(path) do
    case resolve_path(path) do
      {:ok, %{updated_at: %DateTime{} = ts}} -> {:ok, ts}
      _ -> nil
    end
  end

  # The path→entity dispatcher. Kept private so callers go through
  # `freshness_for_path/1` (which returns a `DateTime.t()` for
  # caller convenience) rather than touching the entity shape.
  defp resolve_path("/promoteurs/" <> slug) do
    case get_published_developer_by_slug(slug) do
      nil -> nil
      %Developer{} = d -> {:ok, d}
    end
  end

  defp resolve_path("/projets/" <> rest) do
    {city, slug} = parse_project_path(rest)
    _ = city

    case get_published_project_by_slug(slug) do
      %Project{} = p -> {:ok, p}
      nil -> nil
    end
  end

  defp resolve_path("/" <> rest) do
    # The remaining URL segments after the leading slash. The
    # listing shape is `/{type_segment}/{city}/{slug}`.
    case String.split(rest, "/", parts: 3) do
      [type_segment, _city, slug] -> resolve_listing_path(type_segment, slug)
      _ -> nil
    end
  end

  defp resolve_path(_), do: nil

  # Listing-path helper, split out to keep the depth budget. Looks
  # up the property_type by its fr-locale `url_segment`, then the
  # published listing inside that type's namespace.
  defp resolve_listing_path(type_segment, slug) do
    case find_property_type_by_url_segment(type_segment) do
      %PropertyType{} = pt -> get_published_listing(pt.id, slug)
      _ -> nil
    end
  end

  # /projets/{city}/{slug} → ["{city}", "{slug}"]
  defp parse_project_path(rest) do
    case String.split(rest, "/", parts: 2) do
      [city, slug] -> {city, slug}
      _ -> {nil, nil}
    end
  end

  # Resolve a type_segment to a property_type. Looks at the
  # default-locale (`fr`) `url_segment` per §7.1 — the SSR Worker
  # uses the `fr` segment for canonical URLs. Other locales get
  # alternate paths; freshness check operates on the canonical
  # one.
  defp find_property_type_by_url_segment(nil), do: nil

  defp find_property_type_by_url_segment(segment) when is_binary(segment) do
    PropertyType
    |> where([pt], not is_nil(pt.published_at))
    |> where([pt], pt.published_at <= ^DateTime.utc_now(:second))
    |> where([pt], fragment("? ->> ? = ?", pt.url_segment, ^"fr", ^segment))
    |> Repo.one()
  end

  # Apply cursor (over id) + since (over updated_at) + limit
  # to a query that already has the published predicate composed.
  defp apply_list_filters(query, opts) do
    query
    |> apply_list_filters_no_publish(opts)
  end

  defp apply_list_filters_no_publish(query, opts) do
    query
    |> apply_cursor(opts[:cursor_id])
    |> apply_since(opts[:since])
    |> apply_limit(opts[:limit])
    |> order_by(asc: :id)
  end

  defp apply_cursor(query, nil), do: query

  defp apply_cursor(query, cursor_id) when is_binary(cursor_id) do
    where(query, [r], r.id > ^cursor_id)
  end

  defp apply_since(query, nil), do: query

  defp apply_since(query, %DateTime{} = since) do
    where(query, [r], r.updated_at > ^since)
  end

  defp apply_limit(query, nil), do: query

  defp apply_limit(query, limit) when is_integer(limit) and limit > 0 do
    # Fetch limit+1 so the pagination layer can detect "is there
    # another page?" without a count query.
    limit(query, ^Kernel.+(limit, 1))
  end

  defp apply_limit(query, _), do: query
end
