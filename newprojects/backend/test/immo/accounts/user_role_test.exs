defmodule Immo.Accounts.UserRoleTest do
  use Immo.DataCase, async: true

  alias Immo.Accounts
  alias Immo.Accounts.User
  alias Immo.Catalog.Developer

  @valid_password "Argon2IsGreat!2026"

  describe "user.role enum (§5.8 / §6.2 / A8)" do
    test "rejects unknown role values at changeset time" do
      changeset =
        User.registration_changeset(%User{}, %{
          email: "role-test@example.com",
          role: :wizard
        })

      refute changeset.valid?
      assert %{role: ["is invalid"]} = errors_on(changeset)
    end

    test "rejects developer_id when role is :editor" do
      developer = insert_developer!(%{name: "Editor Binding", slug: "editor-binding"})

      changeset =
        User.registration_changeset(%User{}, %{
          email: "editor-with-dev@example.com",
          role: :editor,
          developer_id: developer.id
        })

      refute changeset.valid?
      assert %{developer_id: ["must be nil unless role is developer_user"]} = errors_on(changeset)
    end

    test "rejects nil developer_id when role is :developer_user" do
      changeset =
        User.registration_changeset(%User{}, %{
          email: "devuser-no-binding@example.com",
          role: :developer_user
        })

      refute changeset.valid?
      assert %{developer_id: ["must be set when role is developer_user"]} = errors_on(changeset)
    end

    test "accepts role=admin with no developer_id" do
      {:ok, user} =
        Accounts.register_staff_user(%{
          email: "admin-ok@example.com",
          password: @valid_password,
          role: :admin
        })

      assert user.role == :admin
      assert is_nil(user.developer_id)
      assert user.confirmed_at
    end

    test "accepts role=developer_user when developer_id is set" do
      developer = insert_developer!(%{name: "Tenant A", slug: "tenant-a"})

      {:ok, user} =
        Accounts.register_staff_user(%{
          email: "tenant-a-user@example.com",
          password: @valid_password,
          role: :developer_user,
          developer_id: developer.id
        })

      assert user.role == :developer_user
      assert user.developer_id == developer.id
    end

    test "DB-level CHECK constraint rejects developer_user without developer_id" do
      # The changeset invariant on `registration_changeset/3` is the first
      # line of defense. To exercise the DB CHECK directly, we build a
      # changeset that circumvents the role/developer_id invariant and
      # then force-insert it. Ecto translates the DB CHECK violation into
      # an `Ecto.ConstraintError` referencing the named constraint.
      user = %User{role: :developer_user, email: "db-bypass@example.com"}
      cs = User.email_changeset(user, %{email: "db-bypass@example.com"})

      assert_raise Ecto.ConstraintError, ~r/users_developer_id_required_iff/, fn ->
        Ecto.Changeset.apply_changes(Ecto.Changeset.put_change(cs, :role, :developer_user))
        |> Map.put(:valid?, true)
        |> Immo.Repo.insert!()
      end
    end

    test "Ecto.Enum allowlist blocks unknown role values before the DB" do
      # Ecto's typed enum stops `:wizard` at the dump layer — the DB
      # CHECK is the second line of defense but the typed enum means
      # application code never has to think about it.
      user = %User{role: :wizard, email: "role-bypass@example.com"}
      cs = User.email_changeset(user, %{email: "role-bypass@example.com"})

      assert_raise Ecto.ChangeError, ~r/does not match type/, fn ->
        Ecto.Changeset.apply_changes(Ecto.Changeset.put_change(cs, :role, :wizard))
        |> Map.put(:valid?, true)
        |> Immo.Repo.insert!()
      end
    end
  end

  describe "role_changeset/2 — privileged update path" do
    test "elevates an editor to admin without touching email or password" do
      {:ok, user} =
        Accounts.register_staff_user(%{
          email: "no-elevation@example.com",
          password: "OriginalPassword!1",
          role: :editor
        })

      original_id = user.id
      original_email = user.email
      original_hashed_password = user.hashed_password

      {:ok, updated} = Accounts.update_user_role(user, %{role: :admin})

      assert updated.id == original_id
      assert updated.email == original_email
      assert updated.hashed_password == original_hashed_password
      assert updated.role == :admin
    end

    test "elevation is idempotent — calling twice does not double-apply" do
      {:ok, user} =
        Accounts.register_staff_user(%{
          email: "idempotent@example.com",
          password: @valid_password,
          role: :admin
        })

      assert {:ok, %User{role: :admin}} = Accounts.update_user_role(user, %{role: :admin})
    end

    test "refuses a malformed role at changeset time" do
      {:ok, user} =
        Accounts.register_staff_user(%{
          email: "refuses-bad-role@example.com",
          password: @valid_password,
          role: :admin
        })

      {:error, changeset} = Accounts.update_user_role(user, %{role: :wizard})
      assert %{role: ["is invalid"]} = errors_on(changeset)
    end
  end

  ## helpers

  defp insert_developer!(attrs) do
    %Developer{
      id: Ecto.UUID.generate(),
      name: Map.fetch!(attrs, :name),
      slug: Map.fetch!(attrs, :slug)
    }
    |> Immo.Repo.insert!()
  end
end
