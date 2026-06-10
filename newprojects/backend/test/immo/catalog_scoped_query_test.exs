defmodule Immo.Catalog.ScopedQueryTest do
  @moduledoc """
  P1-E1.2 §5.8 developer-user tenant-scoping tests.

  Uses `Immo.TestSchemas.TestProject` (a fixture with a `developer_id`
  column) to exercise `Immo.Catalog.scoped_query/2` and
  `Scope.assert_owns_entity/2` against a real table. P1-E2.1 will land
  the production `projects` table; the assertions here are the contract
  that the production listers must uphold.
  """
  use Immo.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Immo.Accounts
  alias Immo.Accounts.Scope
  alias Immo.Catalog
  alias Immo.TestSchemas.TestProject

  setup do
    # Insert real `developers` rows so the `users.developer_id` FK is
    # satisfied when we create developer_users. The Developer stub
    # schema from P1-E1.1 carries `id`, `name`, `slug`; the UUID it
    # generates is the tenant id we use downstream.
    dev_a =
      insert_developer!(%{
        name: "Tenant A",
        slug: "scoped-a-#{System.unique_integer([:positive])}"
      })

    dev_b =
      insert_developer!(%{
        name: "Tenant B",
        slug: "scoped-b-#{System.unique_integer([:positive])}"
      })

    p_a = insert_project!(dev_a.id, "Project A")
    p_b = insert_project!(dev_b.id, "Project B")

    %{tenant_a: dev_a.id, tenant_b: dev_b.id, p_a: p_a, p_b: p_b}
  end

  describe "scoped_query/2 with a developer_user" do
    test "returns only the developer_user's own tenant's rows", ctx do
      dev_user = staff_developer_user(ctx.tenant_a)
      scope = Scope.for_user(dev_user)

      results = Catalog.scoped_query(TestProject, scope) |> Immo.Repo.all()

      assert length(results) == 1
      assert hd(results).id == ctx.p_a.id
    end

    test "filters out other tenants' rows", ctx do
      dev_user = staff_developer_user(ctx.tenant_a)
      scope = Scope.for_user(dev_user)

      results = Catalog.scoped_query(TestProject, scope) |> Immo.Repo.all()

      refute Enum.any?(results, &(&1.id == ctx.p_b.id))
      assert Enum.any?(results, &(&1.id == ctx.p_a.id))
    end

    test "is additive — combines with an existing where clause" do
      dev =
        insert_developer!(%{
          name: "Additive",
          slug: "scoped-add-#{System.unique_integer([:positive])}"
        })

      _matching = insert_project!(dev.id, "Additive Match", "additive-match")
      _other = insert_project!(dev.id, "Additive Other", "additive-other")

      dev_user = staff_developer_user(dev.id)
      scope = Scope.for_user(dev_user)

      base = from(p in TestProject, where: p.slug == ^"additive-match")
      scoped = Catalog.scoped_query(base, scope)

      # Both predicates are applied: slug = "additive-match" AND
      # developer_id = dev.id. The query is the only enforcement point.
      results = scoped |> Immo.Repo.all()
      assert length(results) == 1
      assert hd(results).slug == "additive-match"
    end
  end

  describe "scoped_query/2 with staff roles" do
    test "admin: query passes through unfiltered", _ctx do
      admin = staff_user(:admin)
      scope = Scope.for_user(admin)

      all = Catalog.scoped_query(TestProject, scope) |> Immo.Repo.all()
      assert length(all) == 2
    end

    test "manager: query passes through unfiltered", _ctx do
      manager = staff_user(:manager)
      scope = Scope.for_user(manager)

      all = Catalog.scoped_query(TestProject, scope) |> Immo.Repo.all()
      assert length(all) == 2
    end

    test "editor: query passes through unfiltered", _ctx do
      editor = staff_user(:editor)
      scope = Scope.for_user(editor)

      all = Catalog.scoped_query(TestProject, scope) |> Immo.Repo.all()
      assert length(all) == 2
    end
  end

  describe "scoped_query/2 fail-closed" do
    test "raises when the schema has no developer_id field (developer_user path)" do
      # The fail-closed guard only fires on the developer_user branch of
      # scoped_query/2 — staff queries pass through unchanged. Use a
      # developer_user scope (with a real developer row backing it, so
      # the FK on users.developer_id is satisfied) so the guard actually
      # runs and the test isn't masked by a foreign-key violation.
      dev =
        insert_developer!(%{
          name: "Fail-Closed Dev",
          slug: "fail-closed-#{System.unique_integer([:positive])}"
        })

      scope = Scope.for_user(staff_developer_user(dev.id))

      assert_raise ArgumentError, ~r/does not declare a `:developer_id`/, fn ->
        Catalog.scoped_query(Immo.TestSchemas.NoTenant, scope)
      end
    end
  end

  describe "Scope.assert_owns_entity/2 (§5.8 write-side enforcement)" do
    test "developer_user: :ok when entity belongs to the scope's tenant", ctx do
      dev_user = staff_developer_user(ctx.tenant_a)
      scope = Scope.for_user(dev_user)

      assert Scope.assert_owns_entity(scope, ctx.p_a) == :ok
    end

    test "developer_user: {:error, :forbidden} on cross-tenant entity", ctx do
      # dev_user bound to tenant_a, p_b is owned by tenant_b
      dev_user = staff_developer_user(ctx.tenant_a)
      scope = Scope.for_user(dev_user)

      assert {:error, :forbidden} = Scope.assert_owns_entity(scope, ctx.p_b)
      # And the *own* entity passes — sanity.
      assert Scope.assert_owns_entity(scope, ctx.p_a) == :ok
    end

    test "developer_user denies developer_id=nil entities", ctx do
      dev_user = staff_developer_user(ctx.tenant_a)
      scope = Scope.for_user(dev_user)

      assert {:error, :forbidden} =
               Scope.assert_owns_entity(scope, %{developer_id: nil})
    end

    test "staff roles always pass: assert_owns_entity returns :ok regardless of tenant", ctx do
      for role <- [:admin, :manager, :editor] do
        scope = Scope.for_user(staff_user(role))

        assert Scope.assert_owns_entity(scope, ctx.p_a) == :ok,
               "Expected role=#{role} to pass assert_owns_entity"
      end
    end

    test "anonymous scope: :forbidden" do
      assert {:error, :forbidden} =
               Scope.assert_owns_entity(nil, %{developer_id: Ecto.UUID.generate()})
    end
  end

  ## helpers

  defp insert_developer!(attrs) do
    %Immo.Catalog.Developer{
      id: Ecto.UUID.generate(),
      name: Map.fetch!(attrs, :name),
      slug: Map.fetch!(attrs, :slug)
    }
    |> Immo.Repo.insert!()
  end

  defp insert_project!(
         developer_id,
         title,
         slug \\ "project-#{System.unique_integer([:positive])}"
       ) do
    %TestProject{
      id: Ecto.UUID.generate(),
      title: title,
      slug: slug,
      developer_id: developer_id
    }
    |> Immo.Repo.insert!()
  end

  defp staff_user(role) do
    {:ok, user} =
      Accounts.register_staff_user(%{
        email: "scoped-#{role}-#{System.unique_integer([:positive])}@example.com",
        password: "Test!Pass!2026",
        role: role
      })

    user
  end

  defp staff_developer_user(developer_id) do
    {:ok, user} =
      Accounts.register_staff_user(%{
        email: "dev-user-#{System.unique_integer([:positive])}@example.com",
        password: "Test!Pass!2026",
        role: :developer_user,
        developer_id: developer_id
      })

    user
  end
end
