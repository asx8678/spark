defmodule ImmoWeb.SurfaceRoleTest do
  @moduledoc """
  P1-E1.3 — role × surface integration test (the §16 P1-E1 AC).

  Asserts the §6.2 role-to-surface matrix end-to-end: each role logs
  in, mounts a real LiveView through the router pipeline at
  `/admin/<surface>`, and the test asserts the on_mount outcome
  (render for allow, redirect to `/` for deny). The unit tests in
  `ImmoWeb.UserAuthSurfaceTest` exercise the `on_mount` callback
  directly; this one drives the live_session + LiveView mount path
  to make sure the whole chain — plug, on_mount, halt/cont — agrees.

  ## Why LiveViewTest

  `Phoenix.LiveViewTest.live/2` runs the full mount lifecycle: the
  router dispatches to the live_session, the on_mount callback
  fires, and `mount/3` either runs (allowed) or doesn't (halted
  with redirect). This is the most direct way to assert the
  end-to-end behavior without standing up a real browser.

  The "denied" assertion is `assert_redirected` to `/`, which is
  the path the on_mount hook redirects to on a 403-flash.
  """
  use ImmoWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Immo.Accounts

  @valid_password "P1E1.3!Matrix!2026"

  # §6.2 role-to-surface matrix, in test data. Each row is one role;
  # the inner map is `surface => :allow | :deny`. The `for`-driven
  # tests iterate this map and assert each cell.
  @matrix %{
    admin: %{
      catalog: :allow,
      crm: :allow,
      billing_read: :allow,
      billing_write: :allow,
      admin_only: :allow,
      developer_own: :deny
    },
    manager: %{
      catalog: :allow,
      crm: :allow,
      billing_read: :allow,
      billing_write: :deny,
      admin_only: :deny,
      developer_own: :deny
    },
    editor: %{
      catalog: :allow,
      crm: :deny,
      billing_read: :deny,
      billing_write: :deny,
      admin_only: :deny,
      developer_own: :deny
    },
    developer_user: %{
      catalog: :allow,
      crm: :deny,
      billing_read: :deny,
      billing_write: :deny,
      admin_only: :deny,
      developer_own: :allow
    }
  }

  for {role, expectations} <- @matrix, {surface, expected} <- expectations do
    test "LiveView mount /admin/#{surface} as role=#{role} expected=#{expected}" do
      conn = build_conn_for_role(unquote(role))

      case unquote(expected) do
        :allow ->
          path = "/admin/surface/#{unquote(surface)}"
          {:ok, _view, html} = live(conn, path)
          # The SurfaceLive render includes the surface name in the
          # header — proves the mount ran end-to-end (not halted).
          assert html =~ "Surface: #{unquote(surface)}"

        :deny ->
          # The on_mount hook halts with a redirect to `/`. The
          # LiveViewTest assertion is `assert_redirected` because
          # the view never actually mounts.
          path = "/admin/surface/#{unquote(surface)}"
          conn = get(conn, path)
          assert redirected_to(conn) == ~p"/"
      end
    end
  end

  describe "anonymous caller — every surface denies" do
    for surface <- [:catalog, :crm, :billing_read, :billing_write, :admin_only, :developer_own] do
      test "#{surface} is gated to /users/log-in" do
        # The admin_browser pipeline's `require_authenticated_user` plug
        # runs before the on_mount hook for the live_session, so an
        # anonymous request never reaches the surface gate — it gets
        # bounced to /users/log-in.
        path = "/admin/surface/#{unquote(surface)}"
        conn = get(build_conn(), path)
        assert redirected_to(conn) == ~p"/users/log-in"
      end
    end
  end

  describe "developer_user cross-tenant (§5.8)" do
    # P1-E2 will land the entity listers that use `Immo.Catalog.scoped_query/2`;
    # this test wires the helper end-to-end so a real entity update
    # through the catalog would be denied cross-tenant.
    test "developer_user can write own tenant's row" do
      dev_user = developer_user_with_tenant()
      scope = dev_user.scope
      project = dev_user.own_project

      # Scope-level ownership predicate — the read/write contract that
      # P1-E2's update_project/2 will call before touching the DB.
      assert Immo.Accounts.Scope.assert_owns_entity(scope, project) == :ok
    end

    test "developer_user cannot write another tenant's row" do
      dev_user = developer_user_with_tenant()
      scope = dev_user.scope
      other_project = dev_user.other_tenant_project

      assert Immo.Accounts.Scope.assert_owns_entity(scope, other_project) == {:error, :forbidden}
    end
  end

  describe "session idle timeout (§13) — assertion alongside the matrix" do
    test "session token with last_seen_at 25h ago is rejected end-to-end" do
      # The unit test in `Immo.Accounts.SessionIdleTimeoutTest` exercises
      # the verify query directly. This end-to-end variant goes through
      # the same hook (a LiveView mount) and asserts the user appears
      # unauthenticated. The test rewrites last_seen_at to be 25h old,
      # then attempts to mount /admin — and expects the unauthenticated
      # branch (redirect to /users/log-in) rather than a render.
      user = register_staff_user(:admin)
      token = Accounts.generate_user_session_token(user)
      twenty_five_hours_ago = DateTime.utc_now(:second) |> DateTime.add(-25 * 60 * 60, :second)

      Immo.Repo.update_all(
        from(t in Immo.Accounts.UserToken, where: t.token == ^token),
        set: [last_seen_at: twenty_five_hours_ago]
      )

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.put_session(:user_token, token)
        |> fetch_flash()

      # The verify query filters this token out, so the request arrives
      # as if anonymous — the `require_authenticated_user` plug in the
      # admin pipeline redirects to /users/log-in.
      conn = get(conn, "/admin/surface/catalog")
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  ## helpers

  defp build_conn_for_role(:developer_user) do
    developer = insert_developer!()
    user = register_developer_user(developer.id)
    log_in(user)
  end

  defp build_conn_for_role(role) do
    user = register_staff_user(role)
    log_in(user)
  end

  defp register_staff_user(role) do
    {:ok, user} =
      Accounts.register_staff_user(%{
        email: "matrix-#{role}-#{System.unique_integer([:positive])}@example.com",
        password: @valid_password,
        role: role
      })

    user
  end

  defp register_developer_user(developer_id) do
    {:ok, user} =
      Accounts.register_staff_user(%{
        email: "matrix-dev-#{System.unique_integer([:positive])}@example.com",
        password: @valid_password,
        role: :developer_user,
        developer_id: developer_id
      })

    user
  end

  defp log_in(user) do
    token = Accounts.generate_user_session_token(user)

    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> fetch_flash()
  end

  defp insert_developer! do
    %Immo.Catalog.Developer{
      id: Ecto.UUID.generate(),
      name: "Matrix Test Developer",
      slug: "matrix-test-#{System.unique_integer([:positive])}"
    }
    |> Immo.Repo.insert!()
  end

  # `developer_user_with_tenant/0` builds a developer_user bound to
  # tenant_a, plus a project in tenant_a (own) and tenant_b (other).
  defp developer_user_with_tenant do
    dev_a =
      insert_developer_with_slug!("matrix-cross-a-#{System.unique_integer([:positive])}")

    dev_b =
      insert_developer_with_slug!("matrix-cross-b-#{System.unique_integer([:positive])}")

    dev_user = register_developer_user(dev_a.id)
    scope = Immo.Accounts.Scope.for_user(dev_user)

    own_project = insert_project!(dev_a.id, "own")
    other_project = insert_project!(dev_b.id, "other")

    %{scope: scope, own_project: own_project, other_tenant_project: other_project}
  end

  defp insert_developer_with_slug!(slug) do
    %Immo.Catalog.Developer{id: Ecto.UUID.generate(), name: slug, slug: slug}
    |> Immo.Repo.insert!()
  end

  defp insert_project!(developer_id, slug) do
    %Immo.TestSchemas.TestProject{
      id: Ecto.UUID.generate(),
      title: "Matrix #{slug}",
      slug: slug,
      developer_id: developer_id
    }
    |> Immo.Repo.insert!()
  end
end
