defmodule Immo.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  alias Immo.Catalog.Developer

  @roles [:admin, :manager, :editor, :developer_user]

  schema "users" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true

    # §5.8 / §6.2 staff trust path: role is the RBAC key; developer_id
    # scopes a `developer_user` to their own tenant's data. Invariant
    # `developer_id IS NOT NULL` iff `role = :developer_user` is enforced
    # both at changeset and at the database (CHECK constraint).
    field :role, Ecto.Enum, values: @roles, default: :editor
    belongs_to :developer, Developer, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  A user changeset for registering or changing the email.

  It requires the email to change otherwise an error is added.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the email, useful when displaying live validations.
      Defaults to `true`.
  """
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_email(opts)
  end

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: 160)

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, Immo.Repo)
      |> unique_constraint(:email)
      |> validate_email_changed()
    else
      changeset
    end
  end

  defp validate_email_changed(changeset) do
    if get_field(changeset, :email) && get_change(changeset, :email) == nil do
      add_error(changeset, :email, "did not change")
    else
      changeset
    end
  end

  @doc """
  A user changeset for changing the password.

  It is important to validate the length of the password, as long passwords may
  be very expensive to hash for certain algorithms.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely
      in the database and ensures the password field is cleared to prevent
      leaks in the logs. If password hashing is not needed and clearing the
      password field is not desired (like when using this changeset for
      validations on a LiveView form), this option can be set to `false`.
      Defaults to `true`.
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 72)
    # Examples of additional password validation:
    # |> validate_format(:password, ~r/[a-z]/, message: "at least one lower case character")
    # |> validate_format(:password, ~r/[A-Z]/, message: "at least one upper case character")
    # |> validate_format(:password, ~r/[!?@#$%^&*_0-9]/, message: "at least one digit or punctuation character")
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      # Hashing could be done with `Ecto.Changeset.prepare_changes/2`, but that
      # would keep the database transaction open longer and hurt performance.
      |> put_change(:hashed_password, Argon2.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  def confirm_changeset(user) do
    now = DateTime.utc_now(:second)
    change(user, confirmed_at: now)
  end

  @doc """
  Full registration changeset: sets email, password, role, and (when applicable)
  the developer_id binding. This is the canonical way to create a staff user
  (admin seed, admin "create user" UI, etc.).

  Public self-registration goes through `email_changeset/3` + `password_changeset/3`
  via the generated `UserLive.Registration` flow, which never exposes the role
  field — that path defaults to `:editor` and an admin must elevate privileges.
  """
  def registration_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email, :role, :developer_id])
    |> validate_email(opts)
    |> validate_role()
    |> validate_developer_binding()
    |> put_password(attrs, opts)
  end

  @doc """
  Admin-style changeset to update role and developer_id on an existing user.
  Intentionally refuses to touch email/password (those have their own
  one-purpose flows with extra verification).
  """
  def role_changeset(user, attrs) do
    user
    |> cast(attrs, [:role, :developer_id])
    |> validate_role()
    |> validate_developer_binding()
  end

  defp validate_role(changeset) do
    changeset
    |> validate_inclusion(:role, @roles)
  end

  # §5.8 invariant: developer_id is required iff role = :developer_user.
  # The DB CHECK mirrors this; here we also reject the violation early so
  # the changeset does not even reach the database in the bad shape.
  defp validate_developer_binding(changeset) do
    role = get_field(changeset, :role)
    developer_id = get_field(changeset, :developer_id)

    cond do
      role == :developer_user and is_nil(developer_id) ->
        add_error(changeset, :developer_id, "must be set when role is developer_user")

      role != :developer_user and not is_nil(developer_id) ->
        add_error(changeset, :developer_id, "must be nil unless role is developer_user")

      true ->
        changeset
    end
  end

  defp put_password(changeset, attrs, opts) do
    password = attrs[:password] || attrs["password"]

    if password do
      changeset
      |> put_change(:password, password)
      |> cast(%{"password" => password}, [])
      |> password_changeset(%{password: password}, opts)
    else
      changeset
    end
  end

  @doc """
  Verifies the password.

  If there is no user or the user doesn't have a password, we call
  `Argon2.no_user_verify/0` to avoid timing attacks.
  """
  def valid_password?(%Immo.Accounts.User{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Argon2.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Argon2.no_user_verify()
    false
  end
end
