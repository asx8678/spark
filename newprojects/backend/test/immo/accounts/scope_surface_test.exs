defmodule Immo.Accounts.ScopeSurfaceTest do
  @moduledoc """
  P1-E1.2 §6.2 role-to-surface matrix tests.

  Encodes the expected allow/deny for every (role, surface) pair directly
  from §6.2 of the plan, then asserts `Scope.can_access?/2` resolves
  each one correctly. This is the single source of truth for the matrix
  — when a future role is added or a surface permission changes, the
  test is what tells you whether the matrix is in sync with the plan.
  """
  use ExUnit.Case, async: true

  alias Immo.Accounts.Scope
  alias Immo.Accounts.User

  @surfaces Scope.surfaces()

  # The matrix, in test data. Each row is one role; the inner map is
  # `surface => expected`. The "for"-driven tests below iterate this
  # map and assert each cell.
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
    test "role=#{role} surface=#{surface} expected=#{expected}" do
      scope = scope_for(unquote(role))
      actual = Scope.can_access?(scope, unquote(surface))

      assert actual == unquote(expected),
             "Expected role=#{unquote(role)} on surface=#{unquote(surface)} → #{unquote(expected)}, got #{actual}"
    end
  end

  test "nil scope is denied for every surface" do
    for surface <- @surfaces do
      refute Scope.can_access?(nil, surface)
    end
  end

  test "unknown surface returns false (fail-closed)" do
    scope = scope_for(:admin)
    refute Scope.can_access?(scope, :made_up_surface)
  end

  test "surfaces/0 lists exactly the §6.2 surface groups" do
    assert @surfaces == [
             :catalog,
             :crm,
             :billing_read,
             :billing_write,
             :admin_only,
             :developer_own
           ]
  end

  ## helpers

  defp scope_for(role) do
    %User{id: 1, email: "#{role}@example.com", role: role, developer_id: tenant_id_for(role)}
    |> Scope.for_user()
  end

  defp tenant_id_for(:developer_user), do: Ecto.UUID.generate()
  defp tenant_id_for(_), do: nil
end
