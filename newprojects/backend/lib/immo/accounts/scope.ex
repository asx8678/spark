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
  the `developer_user` role (nil for staff roles). The `admin?/1`, `manager?/1`,
  `editor?/1`, and `developer_user?/1` helpers are the only place this mapping
  is expressed — authorization code reads them, never raw role atoms.
  """

  alias Immo.Accounts.User

  defstruct user: nil, role: nil, developer_id: nil

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
  Use this in query scopes: `Catalog.list_projects(developer_id: scope.tenant_id)`.
  """
  def tenant_id(%__MODULE__{developer_id: id}) when is_binary(id), do: id
  def tenant_id(_), do: nil
end
