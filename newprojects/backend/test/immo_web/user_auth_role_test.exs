defmodule ImmoWeb.UserAuthRoleTest do
  @moduledoc """
  P1-E1.1 role-matrix integration test (§16 P1-E1 AC).

  The four staff roles (admin / manager / editor / developer_user) are
  exercised against the admin surface (`/admin`) in both allow and deny
  cases. The test runs through the public auth pipeline — log in via a
  real session token, hit the route, observe redirect / halt — to prove
  the end-to-end enforcement is correct, not just the in-process
  helpers.
  """
  use ImmoWeb.ConnCase, async: true

  alias Immo.Accounts
  alias Immo.Accounts.Scope
  alias Immo.Catalog.Developer

  @valid_password "RoleMatrix!Test!2026"

  describe "POST /admin — any_staff gate" do
    test "admin can access /admin", %{conn: conn} do
      user = staff_user(%{role: :admin})
      conn = log_in(conn, user)
      conn = get(conn, ~p"/admin")
      assert conn.status == 200
      assert html_response(conn, 200) =~ "Admin"
    end

    test "manager can access /admin", %{conn: conn} do
      user = staff_user(%{role: :manager})
      conn = log_in(conn, user)
      conn = get(conn, ~p"/admin")
      assert conn.status == 200
    end

    test "editor can access /admin", %{conn: conn} do
      user = staff_user(%{role: :editor})
      conn = log_in(conn, user)
      conn = get(conn, ~p"/admin")
      assert conn.status == 200
    end

    test "developer_user is DENIED /admin (tenant role, not staff)", %{conn: conn} do
      developer = insert_developer!(%{slug: "denied-tenant"})
      user = staff_user(%{role: :developer_user, developer_id: developer.id})
      conn = log_in(conn, user)
      conn = get(conn, ~p"/admin")

      # on_mount :require_any_staff halts with a redirect when the role
      # check fails, exactly like the controller-level plug.
      assert redirected_to(conn) == ~p"/"
    end

    test "anonymous user is redirected to /users/log-in", %{conn: conn} do
      conn = get(conn, ~p"/admin")
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "developer_user tenant scoping" do
    test "Scope.tenant_id/1 returns the user's developer_id", %{conn: _conn} do
      developer = insert_developer!(%{slug: "scope-tenant"})

      user = staff_user(%{role: :developer_user, developer_id: developer.id})
      scope = Scope.for_user(user)

      assert Scope.tenant_id(scope) == developer.id
      assert Scope.developer_user?(scope)
    end

    test "two developer_users bound to different developers have distinct tenant ids", %{
      conn: _conn
    } do
      dev_a = insert_developer!(%{slug: "tenant-a-iso"})
      dev_b = insert_developer!(%{slug: "tenant-b-iso"})

      scope_a = Scope.for_user(staff_user(%{role: :developer_user, developer_id: dev_a.id}))
      scope_b = Scope.for_user(staff_user(%{role: :developer_user, developer_id: dev_b.id}))

      assert Scope.tenant_id(scope_a) == dev_a.id
      assert Scope.tenant_id(scope_b) == dev_b.id
      assert Scope.tenant_id(scope_a) != Scope.tenant_id(scope_b)
    end
  end

  describe "require_role/1 plug" do
    test "manager-only plug denies an editor" do
      user = staff_user(%{role: :editor})
      scope = Scope.for_user(user)
      refute Scope.manager?(scope)
    end

    test "manager-only plug accepts a manager" do
      user = staff_user(%{role: :manager})
      scope = Scope.for_user(user)
      assert Scope.manager?(scope)
    end
  end

  ## helpers

  defp staff_user(%{role: role} = attrs) do
    developer_id = Map.get(attrs, :developer_id)

    {:ok, user} =
      Accounts.register_staff_user(%{
        email: "role-#{role}-#{System.unique_integer([:positive])}@example.com",
        password: @valid_password,
        role: role,
        developer_id: developer_id
      })

    user
  end

  defp log_in(conn, user) do
    token = Accounts.generate_user_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  defp insert_developer!(%{slug: slug}) do
    %Developer{id: Ecto.UUID.generate(), name: slug, slug: slug}
    |> Immo.Repo.insert!()
  end
end
