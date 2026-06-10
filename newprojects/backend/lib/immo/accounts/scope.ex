defmodule Immo.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `Immo.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from
  an end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use as authorization, or to
  ensure specific code paths can only be access for a given scope.

  It is useful for logging as well as for scoping pubsub subscriptions and
  broadcasts when a caller subscribes to an interface or performs a particular
  action.

  ## RBAC (§6.2 / §5.8)

  `role` is the staff privilege set; `developer_id` is the tenant binding for
  the `developer_user` role (nil for staff roles). The role predicates
  (`admin?/1`, `manager?/1`, `editor?/1`, `developer_user?/1`) describe the
  staff hierarchy (admin ⊃ manager ⊃ editor). The `can_access?/2` helper
  resolves a request against a *surface group* (`:catalog`, `:crm`,
  `:billing_read`, `:billing_write`, `:admin_only`, `:developer_own`) using
  the §6.2 role-to-surface matrix.

  Authorization code reads these helpers — never raw role atoms. The matrix
  is encoded exactly once, in `can_access?/2`.

  ## Developer-user tenant scoping (§5.8)

  `developer_user?/1` roles carry a non-nil `developer_id`. The
  `tenant_id/1` helper returns it. All catalog queries for a
  `developer_user` MUST be filtered to `where entity.developer_id = ^
  scope.tenant_id`; the catalog context owns this via
  `Immo.Catalog.scoped_query/2`. Failing to apply the filter is a §5.8
  security violation — the on_mount hook only blocks the page render,
  the query is the actual defense.

  Write-side enforcement (P1-E1.2) lives in `assert_owns_entity/2`:
  P1-E2's `update_*` / `delete_*` changesets call this helper to refuse
  any mutation whose target `developer_id` does not match
  `scope.tenant_id` for a `developer_user`. Staff roles pass through
  without a check. The read-side `scoped_query/2` and the write-side
  `assert_owns_entity/2` together form the §5.8 enforcement pair.
  """

  alias Immo.Accounts.User

  defstruct user: nil, role: nil, developer_id: nil

  # Surface groups per §6.2 / P1-E1.2. The §6.2 role-to-surface matrix is
  # encoded exactly once in `can_access?/2` — the only place staff surface
  # authorization decisions are made.
  #
  #   * `:catalog`         — projects, listings, property types, custom fields.
  #                          All staff (incl. developer_user) read here; the
  #                          developer_user path is tenant-scoped (see Catalog).
  #   * `:crm`             — inquiries inbox (read + write).
  #   * `:billing_read`    — subscriptions, payments (no write).
  #   * `:billing_write`   — manual "mark paid", plan changes, refunds.
  #   * `:admin_only`      — audit log viewer, user management, role assignment.
  #   * `:developer_own`   — the "my projects / my listings" surface a
  #                          developer_user sees as their home.
  @surfaces [:catalog, :crm, :billing_read, :billing_write, :admin_only, :developer_own]

  @doc """
  The full set of surface groups. Exposed so router and LiveView
  configurations can refer to it without restating the atoms.
  """
  def surfaces, do: @surfaces

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user) do
    %__MODULE__{
      user: user,
      role: user.role,
      developer_id: user.developer_id
    }
  end

  def for_user(nil), do: nil

  @doc "True when the scope has an authenticated user."
  def authenticated?(%__MODULE__{user: %User{}}), do: true
  def authenticated?(_), do: false

  @doc "True when the user has the `:admin` role."
  def admin?(%__MODULE__{role: :admin}), do: true
  def admin?(_), do: false

  @doc """
  `manager` (catalog + CRM + billing-read) per §6.2. Admin is implicitly
  also a manager for permission checks — admin is a superset.
  """
  def manager?(%__MODULE__{role: role}) when role in [:admin, :manager], do: true
  def manager?(_), do: false

  @doc "`editor` (catalog only) per §6.2. Manager and admin are supersets."
  def editor?(%__MODULE__{role: role}) when role in [:admin, :manager, :editor], do: true
  def editor?(_), do: false

  @doc "`developer_user` — always exactly that role; the only role that carries a `developer_id`."
  def developer_user?(%__MODULE__{role: :developer_user}), do: true
  def developer_user?(_), do: false

  @doc """
  The tenant id a `developer_user` is bound to; `nil` for staff roles.
  Use this in query scopes: `Immo.Catalog.scoped_query(scope)`.
  """
  def tenant_id(%__MODULE__{developer_id: id}) when is_binary(id), do: id
  def tenant_id(_), do: nil

  @doc """
  Resolve a surface-group access request against this scope per the §6.2
  role-to-surface matrix. The matrix, encoded exactly once here:

      surface         | admin | manager | editor | developer_user
      ---------------+-------+---------+--------+----------------
      :catalog        |  ✓   |   ✓    |   ✓    |   ✓ (tenant-scoped)
      :crm            |  ✓   |   ✓    |   ✗    |   ✗
      :billing_read   |  ✓   |   ✓    |   ✗    |   ✗
      :billing_write  |  ✓   |   ✗    |   ✗    |   ✗
      :admin_only     |  ✓   |   ✗    |   ✗    |   ✗
      :developer_own  |  ✗   |   ✗    |   ✗    |   ✓

  The `:catalog` row says "yes for any of the four roles", but for
  `developer_user` the catalog queries are tenant-scoped (see
  `Immo.Catalog.scoped_query/2`). The on_mount hook here gates page render;
  the query is the actual defense against cross-tenant reads.
  """
  def can_access?(%__MODULE__{} = scope, surface) when surface in @surfaces do
    case surface do
      :catalog -> editor?(scope) or developer_user?(scope)
      :crm -> manager?(scope)
      :billing_read -> manager?(scope)
      :billing_write -> admin?(scope)
      :admin_only -> admin?(scope)
      :developer_own -> developer_user?(scope)
    end
  end

  def can_access?(_scope, _surface), do: false

  @doc """
  Predicate form of the §5.8 write-side tenant check. True when the
  scope is allowed to mutate the given entity, false otherwise.

  Rules:

    * `developer_user`: allowed iff `entity.developer_id == scope.developer_id`.
    * All staff roles: always allowed.
    * Anonymous (`nil` scope): never allowed.

  The entity MUST expose a `developer_id` field. This is the §5.8
  contract: every catalog entity that a `developer_user` can write is
  tenant-bound, and the field name is fixed. The query-side helper
  `Immo.Catalog.scoped_query/2` enforces the same invariant for reads.
  """
  def can_own_entity?(%__MODULE__{role: :developer_user} = scope, %{developer_id: id})
      when is_binary(id) and is_binary(scope.developer_id) do
    id == scope.developer_id
  end

  def can_own_entity?(%__MODULE__{role: :developer_user}, _entity), do: false

  def can_own_entity?(%__MODULE__{role: role}, _entity) when role in [:admin, :manager, :editor],
    do: true

  def can_own_entity?(nil, _entity), do: false

  @doc """
  Action-at-a-distance form of `can_own_entity?/2` for use in
  changeset update/delete functions: returns `:ok` when the scope may
  mutate the entity, `{:error, :forbidden}` otherwise. P1-E2's
  `update_project/2` etc. call this before touching the DB so the
  write path mirrors the read path's tenant filter.
  """
  def assert_owns_entity(scope, entity) do
    if can_own_entity?(scope, entity) do
      :ok
    else
      {:error, :forbidden}
    end
  end
end
