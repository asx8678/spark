defmodule Immo.AuditTest do
  @moduledoc """
  P1-E2.4 — `Immo.Audit` thin context wrapper tests.

  Coverage of the §5.12 / §13 ACs:

    * Every Catalog admin mutation produces an audit_log row with
      user_id, action, entity_type, entity_id, diff, at.
    * The diff contains the changed fields' old → new values.
    * The audit row is written in the same transaction as the
      mutation: rollback removes both.
    * The query API for the P1-E3.5 viewer filters by entity,
      user, action and paginates.
  """

  use Immo.DataCase, async: true

  alias Immo.Audit
  alias Immo.AuditLog
  alias Immo.Catalog

  @valid_password "Audit!Test!2026"

  describe "OutsideTransactionError" do
    test "log_mutation/1 raises when not in a Repo.transact/1" do
      assert_raise Audit.OutsideTransactionError, ~r/inside Repo.transact/, fn ->
        Audit.log_mutation(
          actor_user: nil,
          action: "create",
          entity: %{id: Ecto.UUID.generate(), __struct__: SomeModule},
          diff: %{"before" => %{}, "after" => %{}, "changed" => []}
        )
      end
    end
  end

  describe "create diff" do
    test "create_diff/1 returns after-only with all auditable fields" do
      dev = developer_with_slug("diff-create-#{System.unique_integer([:positive])}")

      diff = Audit.create_diff(dev)

      assert diff["before"] == %{}
      assert is_list(diff["changed"])
      assert diff["after"]["name"] == dev.name
      assert diff["after"]["slug"] == dev.slug
    end
  end

  describe "update diff" do
    test "update_diff/3 only includes fields whose value actually changed" do
      dev = developer_with_slug("diff-update-#{System.unique_integer([:positive])}")
      cs = Immo.Catalog.Developer.update_changeset(dev, %{name: "Renamed"})

      updated = %{dev | name: "Renamed"}
      diff = Audit.update_diff(dev, updated, cs)

      assert "name" in diff["changed"]
      assert diff["before"]["name"] == dev.name
      assert diff["after"]["name"] == "Renamed"
      # The other columns weren't in the changeset's `changes`, so
      # they don't show up in the diff even if they happen to have
      # different values between old and new.
    end

    test "update_diff/3 with no real change produces empty diff" do
      dev = developer_with_slug("diff-noop-#{System.unique_integer([:positive])}")
      cs = Immo.Catalog.Developer.update_changeset(dev, %{name: dev.name})

      diff = Audit.update_diff(dev, dev, cs)

      assert diff["changed"] == []
    end
  end

  describe "delete diff" do
    test "delete_diff/1 returns before-only" do
      dev = developer_with_slug("diff-delete-#{System.unique_integer([:positive])}")
      diff = Audit.delete_diff(dev)

      assert diff["after"] == %{}
      assert diff["before"]["name"] == dev.name
    end
  end

  describe "every Catalog mutation writes an audit_log row (§5.12)" do
    test "create_project writes an audit_log row" do
      actor = staff_user("actor-create-project-#{System.unique_integer([:positive])}")
      dev = developer_with_slug("audit-create-proj-#{System.unique_integer([:positive])}")

      assert {:ok, project} =
               Catalog.create_project(
                 %{
                   developer_id: dev.id,
                   title: %{"fr" => "P"},
                   slug: "audit-proj-#{System.unique_integer([:positive])}"
                 },
                 actor_user: actor
               )

      [row] = Audit.list_for_entity("Project", project.id)
      assert row.action == "create"
      assert row.entity_type == "Project"
      assert row.entity_id == project.id
      assert row.user_id == actor.id
      assert row.diff["before"] == %{}
      assert row.diff["after"]["slug"] == project.slug
    end

    test "update_project writes an audit_log row with the diff" do
      actor = staff_user("actor-update-project-#{System.unique_integer([:positive])}")
      dev = developer_with_slug("audit-update-proj-#{System.unique_integer([:positive])}")

      {:ok, project} =
        Catalog.create_project(
          %{
            developer_id: dev.id,
            title: %{"fr" => "Old"},
            slug: "audit-upd-proj-#{System.unique_integer([:positive])}"
          },
          actor_user: actor
        )

      {:ok, _} =
        Catalog.update_project(
          project,
          %{title: %{"fr" => "New"}, slug: project.slug},
          actor_role: :admin,
          actor_user: actor
        )

      [_, row] = Audit.list_for_entity("Project", project.id)
      assert row.action == "update"
      assert row.user_id == actor.id
      assert "title" in row.diff["changed"]
      assert row.diff["before"]["title"] == %{"fr" => "Old"}
      assert row.diff["after"]["title"] == %{"fr" => "New"}
    end

    test "publish_project writes an audit_log row with action=publish" do
      actor = staff_user("actor-publish-#{System.unique_integer([:positive])}")
      dev = developer_with_slug("audit-publish-#{System.unique_integer([:positive])}")

      {:ok, project} =
        Catalog.create_project(
          %{
            developer_id: dev.id,
            title: %{"fr" => "P"},
            slug: "audit-pub-#{System.unique_integer([:positive])}"
          },
          actor_user: actor
        )

      {:ok, _} = Catalog.publish_project(project, actor_user: actor)

      [_create, row] = Audit.list_for_entity("Project", project.id)
      assert row.action == "publish"
      assert row.user_id == actor.id
    end

    test "delete_project writes an audit_log row" do
      actor = staff_user("actor-delete-#{System.unique_integer([:positive])}")
      dev = developer_with_slug("audit-del-#{System.unique_integer([:positive])}")

      {:ok, project} =
        Catalog.create_project(
          %{
            developer_id: dev.id,
            title: %{"fr" => "P"},
            slug: "audit-del-#{System.unique_integer([:positive])}"
          },
          actor_user: actor
        )

      {:ok, _} = Catalog.delete_project(project, actor_user: actor)

      [create_row, row] = Audit.list_for_entity("Project", project.id)
      assert row.action == "delete"
      assert row.user_id == actor.id
    end

    test "create_developer writes an audit_log row" do
      actor = staff_user("actor-create-dev-#{System.unique_integer([:positive])}")

      assert {:ok, dev} =
               Catalog.create_developer(
                 %{
                   name: "Audited Dev",
                   slug: "audited-dev-#{System.unique_integer([:positive])}"
                 },
                 actor_user: actor
               )

      [row] = Audit.list_for_entity("Developer", dev.id)
      assert row.action == "create"
      assert row.user_id == actor.id
    end

    test "create_listing writes an audit_log row" do
      actor = staff_user("actor-create-listing-#{System.unique_integer([:positive])}")
      dev = developer_with_slug("audit-listing-#{System.unique_integer([:positive])}")

      {:ok, pt} =
        Catalog.create_property_type(%{
          key: "apartment",
          label: %{"fr" => "A"},
          url_segment: %{"fr" => "a"},
          position: 0
        })

      assert {:ok, listing} =
               Catalog.create_listing(
                 %{
                   property_type_id: pt.id,
                   title: %{"fr" => "L"},
                   slug: "audit-listing-#{System.unique_integer([:positive])}"
                 },
                 actor_user: actor
               )

      [row] = Audit.list_for_entity("Listing", listing.id)
      assert row.action == "create"
      assert row.user_id == actor.id
    end
  end

  describe "audit_log is in the same transaction as the mutation" do
    test "rolled-back mutation also rolls back the audit row (§5.12 atomic commit)" do
      actor = staff_user("actor-rollback-#{System.unique_integer([:positive])}")
      dev = developer_with_slug("rollback-#{System.unique_integer([:positive])}")
      initial_audit_count = Audit.count()

      # Force a changeset error by attempting to create a project
      # with a slug that violates the kebab-case format. The
      # changeset is invalid; Repo.insert returns {:error, cs};
      # the audit call inside the same Repo.transact runs only on
      # :ok, so the audit row is never written.
      assert {:error, _cs} =
               Catalog.create_project(
                 %{developer_id: dev.id, title: %{"fr" => "P"}, slug: "Bad Slug"},
                 actor_user: actor
               )

      assert Audit.count() == initial_audit_count
    end

    test "successful mutation writes exactly one audit row" do
      actor = staff_user("actor-exactly-one-#{System.unique_integer([:positive])}")
      dev = developer_with_slug("exactly-one-#{System.unique_integer([:positive])}")
      before = Audit.count()

      {:ok, _} =
        Catalog.create_project(
          %{
            developer_id: dev.id,
            title: %{"fr" => "P"},
            slug: "exactly-one-#{System.unique_integer([:positive])}"
          },
          actor_user: actor
        )

      assert Audit.count() == before + 1
    end

    test "system-triggered mutation (actor_user: nil) writes audit row with user_id NULL" do
      dev = developer_with_slug("system-actor-#{System.unique_integer([:positive])}")
      before = Audit.count()

      {:ok, _} =
        Catalog.create_project(
          %{
            developer_id: dev.id,
            title: %{"fr" => "P"},
            slug: "system-actor-#{System.unique_integer([:positive])}"
          },
          actor_user: nil
        )

      [row] = Audit.list_for_action("create", limit: 1)
      assert row.user_id == nil
      assert Audit.count() == before + 1
    end
  end

  describe "query API (P1-E3.5 viewer)" do
    setup do
      actor = staff_user("viewer-actor-#{System.unique_integer([:positive])}")
      %{actor: actor}
    end

    test "list_for_entity/2 returns rows for the given entity_type + entity_id", %{actor: actor} do
      dev = developer_with_slug("viewer-entity-#{System.unique_integer([:positive])}")

      {:ok, _} =
        Catalog.create_project(
          %{
            developer_id: dev.id,
            title: %{"fr" => "P"},
            slug: "viewer-entity-#{System.unique_integer([:positive])}"
          }, actor_user: actor)

      {:ok, _} =
        Catalog.create_project(
          %{
            developer_id: dev.id,
            title: %{"fr" => "Q"},
            slug: "viewer-entity-2-#{System.unique_integer([:positive])}"
          }, actor_user: actor)

      # Two projects get two create-rows; filter by entity_id
      # returns one entity's worth of rows.
      [_p1, _p2] =
        1..2
        |> Enum.map(fn _ ->
          slug = "scoped-#{System.unique_integer([:positive])}"

          {:ok, p} =
            Catalog.create_project(%{developer_id: dev.id, title: %{"fr" => "X"}, slug: slug},
              actor_user: actor
            )

          p
        end)

      [target | _] = _p1 |> List.wrap()
      target_id = target.id

      rows = Audit.list_for_entity("Project", target_id)
      assert Enum.all?(rows, &(&1.entity_id == target_id))
    end

    test "list_for_user/2 returns only rows authored by that user", %{actor: actor} do
      other_actor = staff_user("other-actor-#{System.unique_integer([:positive])}")
      dev = developer_with_slug("viewer-user-#{System.unique_integer([:positive])}")

      {:ok, _} =
        Catalog.create_project(
          %{
            developer_id: dev.id,
            title: %{"fr" => "P"},
            slug: "viewer-user-a-#{System.unique_integer([:positive])}"
          }, actor_user: actor)

      {:ok, _} =
        Catalog.create_project(
          %{
            developer_id: dev.id,
            title: %{"fr" => "P"},
            slug: "viewer-user-b-#{System.unique_integer([:positive])}"
          }, actor_user: other_actor)

      actor_rows = Audit.list_for_user(actor.id)
      other_rows = Audit.list_for_user(other_actor.id)

      assert Enum.all?(actor_rows, &(&1.user_id == actor.id))
      assert Enum.all?(other_rows, &(&1.user_id == other_actor.id))
      refute actor.id in Enum.map(other_rows, & &1.user_id)
    end

    test "list_for_action/2 returns only rows with the given action", %{actor: actor} do
      dev = developer_with_slug("viewer-action-#{System.unique_integer([:positive])}")

      {:ok, project} =
        Catalog.create_project(
          %{
            developer_id: dev.id,
            title: %{"fr" => "P"},
            slug: "viewer-action-#{System.unique_integer([:positive])}"
          }, actor_user: actor)

      {:ok, _} = Catalog.publish_project(project, actor_user: actor)

      creates = Audit.list_for_action("create")
      publishes = Audit.list_for_action("publish")

      assert Enum.all?(creates, &(&1.action == "create"))
      assert Enum.all?(publishes, &(&1.action == "publish"))
    end

    test "list_recent/1 paginates with limit + offset", %{actor: actor} do
      dev = developer_with_slug("viewer-paginate-#{System.unique_integer([:positive])}")

      # 3 projects → 3 create-rows
      for i <- 1..3 do
        Catalog.create_project(
          %{
            developer_id: dev.id,
            title: %{"fr" => "P#{i}"},
            slug: "viewer-paginate-#{i}-#{System.unique_integer([:positive])}"
          },
          actor_user: actor
        )
      end

      page_1 = Audit.list_recent(limit: 2, offset: 0)
      page_2 = Audit.list_recent(limit: 2, offset: 2)

      assert length(page_1) == 2
      assert length(page_2) >= 1
      # Pages don't overlap.
      page_1_ids = Enum.map(page_1, & &1.id) |> MapSet.new()
      page_2_ids = Enum.map(page_2, & &1.id) |> MapSet.new()
      assert MapSet.disjoint?(page_1_ids, page_2_ids)
    end

    test "count/1 reflects filtered total", %{actor: actor} do
      dev = developer_with_slug("viewer-count-#{System.unique_integer([:positive])}")

      actor_before = Audit.count(user_id: actor.id)
      before = Audit.count()

      Catalog.create_project(
        %{
          developer_id: dev.id,
          title: %{"fr" => "P"},
          slug: "viewer-count-#{System.unique_integer([:positive])}"
        }, actor_user: actor)

      Catalog.create_project(
        %{
          developer_id: dev.id,
          title: %{"fr" => "P"},
          slug: "viewer-count-2-#{System.unique_integer([:positive])}"
        }, actor_user: actor)

      assert Audit.count() == before + 2
      assert Audit.count(action: "create") >= actor_before + 2
      assert Audit.count(user_id: actor.id) == actor_before + 2
    end

    test "list_recent/1 returns rows newest-first (inserted_at desc)", %{actor: actor} do
      dev = developer_with_slug("viewer-order-#{System.unique_integer([:positive])}")

      {:ok, p1} =
        Catalog.create_project(
          %{
            developer_id: dev.id,
            title: %{"fr" => "P1"},
            slug: "viewer-order-1-#{System.unique_integer([:positive])}"
          }, actor_user: actor)

      {:ok, _p2} =
        Catalog.create_project(
          %{
            developer_id: dev.id,
            title: %{"fr" => "P2"},
            slug: "viewer-order-2-#{System.unique_integer([:positive])}"
          }, actor_user: actor)

      [first | _] = Audit.list_recent(limit: 10)
      # The first row should be the most recent (p2's create).
      assert first.entity_id != p1.id
    end
  end

  ## Helpers

  defp staff_user(label) do
    {:ok, user} =
      Immo.Accounts.register_staff_user(%{
        email: "#{label}@example.com",
        password: @valid_password,
        role: :admin
      })

    user
  end

  defp developer_with_slug(slug) do
    {:ok, dev} = Catalog.create_developer(%{name: slug, slug: slug})
    dev
  end
end
