defmodule Immo.Accounts.ScopeTest do
  use ExUnit.Case, async: true

  alias Immo.Accounts.Scope
  alias Immo.Accounts.User

  describe "role hierarchy (§6.2)" do
    test "admin?/1 is true only for :admin" do
      assert Scope.admin?(%Scope{role: :admin})
      refute Scope.admin?(%Scope{role: :manager})
      refute Scope.admin?(%Scope{role: :editor})
      refute Scope.admin?(%Scope{role: :developer_user})
    end

    test "manager?/1 is true for admin + manager (admin is a superset)" do
      assert Scope.manager?(%Scope{role: :admin})
      assert Scope.manager?(%Scope{role: :manager})
      refute Scope.manager?(%Scope{role: :editor})
      refute Scope.manager?(%Scope{role: :developer_user})
    end

    test "editor?/1 is true for admin + manager + editor (catalog is the most permissive staff surface)" do
      assert Scope.editor?(%Scope{role: :admin})
      assert Scope.editor?(%Scope{role: :manager})
      assert Scope.editor?(%Scope{role: :editor})
      refute Scope.editor?(%Scope{role: :developer_user})
    end

    test "developer_user?/1 is true only for the :developer_user role" do
      assert Scope.developer_user?(%Scope{role: :developer_user})
      refute Scope.developer_user?(%Scope{role: :admin})
      refute Scope.developer_user?(%Scope{role: :manager})
      refute Scope.developer_user?(%Scope{role: :editor})
    end

    test "tenant_id/1 returns the developer_id only for developer_users" do
      dev_id = Ecto.UUID.generate()
      assert Scope.tenant_id(%Scope{role: :developer_user, developer_id: dev_id}) == dev_id
      assert Scope.tenant_id(%Scope{role: :admin, developer_id: nil}) == nil
    end
  end

  describe "for_user/1" do
    test "populates role and developer_id from the user struct" do
      dev_id = Ecto.UUID.generate()

      user = %User{
        id: 42,
        email: "fixture@example.com",
        role: :developer_user,
        developer_id: dev_id
      }

      scope = Scope.for_user(user)
      assert scope.user.id == 42
      assert scope.role == :developer_user
      assert scope.developer_id == dev_id
    end

    test "returns nil for nil" do
      assert Scope.for_user(nil) == nil
    end

    test "authenticated?/1 is true only for a scope with a user" do
      assert Scope.authenticated?(%Scope{user: %User{}})
      refute Scope.authenticated?(%Scope{user: nil})
      refute Scope.authenticated?(nil)
    end
  end
end
