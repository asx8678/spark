defmodule ImmoWeb.UserAuthSurfaceTest do
  @moduledoc """
  P1-E1.2 surface-parameterized on_mount hook + plug.

  The matrix is encoded in `Immo.Accounts.Scope.can_access?/2` (covered
  by `Immo.Accounts.ScopeSurfaceTest`). The tests here exercise the
  on_mount hook + the plug side — that they actually enforce the matrix
  at request time, not just at the helper layer.
  """
  use ImmoWeb.ConnCase, async: true

  alias Immo.Accounts
  alias ImmoWeb.UserAuth
  alias Phoenix.LiveView

  @valid_password "Surface!Matrix!2026"

  @matrix %{
    admin: %{
      catalog: true,
      crm: true,
      billing_read: true,
      billing_write: true,
      admin_only: true,
      developer_own: false
    },
    manager: %{
      catalog: true,
      crm: true,
      billing_read: true,
      billing_write: false,
      admin_only: false,
      developer_own: false
    },
    editor: %{
      catalog: true,
      crm: false,
      billing_read: false,
      billing_write: false,
      admin_only: false,
      developer_own: false
    },
    developer_user: %{
      catalog: true,
      crm: false,
      billing_read: false,
      billing_write: false,
      admin_only: false,
      developer_own: true
    }
  }

  for {role, expectations} <- @matrix, {surface, expected} <- expectations do
    test "on_mount {:require_surface, #{surface}} for role=#{role} expected=#{expected}" do
      user = fixture_for_role(unquote(role))
      session = build_session(user)
      socket = build_socket()

      result =
        UserAuth.on_mount(
          {:require_surface, unquote(surface)},
          %{},
          session,
          socket
        )

      if unquote(expected) do
        assert {:cont, _updated_socket} = result
      else
        assert {:halt, _updated_socket} = result
      end
    end
  end

  describe "on_mount {:require_surface, _} — anonymous" do
    for surface <- [:catalog, :crm, :billing_read, :billing_write, :admin_only, :developer_own] do
      test "#{surface}: anonymous caller is halted and redirected to login" do
        socket = build_socket()
        session = %{}

        assert {:halt, _socket} =
                 UserAuth.on_mount({:require_surface, unquote(surface)}, %{}, session, socket)
      end
    end
  end

  describe "require_surface/1 plug" do
    test "allows a manager through :crm" do
      user = fixture_for_role(:manager)
      conn = fetch_flash(log_in(build_conn(), user)) |> UserAuth.fetch_current_scope_for_user([])

      plug = UserAuth.require_surface(:crm)
      refute plug.(conn, []).halted
    end

    test "halts and flashes when an editor tries :crm" do
      user = fixture_for_role(:editor)
      conn = fetch_flash(log_in(build_conn(), user)) |> UserAuth.fetch_current_scope_for_user([])

      plug = UserAuth.require_surface(:crm)
      assert plug.(conn, []).halted
    end

    test "halts an anonymous caller" do
      # Build a conn with a session + flash fetched (the auth pipeline
      # calls `get_session/1` internally, the require_surface plug calls
      # `put_flash/3`); with no user_token in it.
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> fetch_flash()
        |> UserAuth.fetch_current_scope_for_user([])

      plug = UserAuth.require_surface(:catalog)
      assert plug.(conn, []).halted
    end
  end

  ## helpers

  defp fixture_for_role(:developer_user) do
    developer = insert_developer!()
    staff_developer_user(developer.id)
  end

  defp fixture_for_role(role) do
    staff_user(role)
  end

  defp staff_user(role) do
    {:ok, user} =
      Accounts.register_staff_user(%{
        email: "surface-#{role}-#{System.unique_integer([:positive])}@example.com",
        password: @valid_password,
        role: role
      })

    user
  end

  defp staff_developer_user(developer_id) do
    {:ok, user} =
      Accounts.register_staff_user(%{
        email: "surface-dev-#{System.unique_integer([:positive])}@example.com",
        password: @valid_password,
        role: :developer_user,
        developer_id: developer_id
      })

    user
  end

  defp insert_developer! do
    %Immo.Catalog.Developer{
      id: Ecto.UUID.generate(),
      name: "Surface Test Developer",
      slug: "surface-test-#{System.unique_integer([:positive])}"
    }
    |> Immo.Repo.insert!()
  end

  defp build_session(user) do
    token = Accounts.generate_user_session_token(user)

    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.get_session()
  end

  defp log_in(conn, user) do
    token = Accounts.generate_user_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  defp build_socket do
    %LiveView.Socket{
      endpoint: ImmoWeb.Endpoint,
      assigns: %{__changed__: %{}, flash: %{}}
    }
  end
end
