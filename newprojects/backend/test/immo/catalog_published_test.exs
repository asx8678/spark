defmodule Immo.Catalog.PublishedTest do
  @moduledoc """
  P1-E2.3 — §15.1 predicate matrix tests for `Immo.Catalog.published/1`.

  The matrix covers the axes from §15.1:

    * `published_at`: null, future, past
    * Subscription state (for projects/listings): none, trialing,
      active, past_due, canceled
    * `BILLING_ENFORCED`: true, false

  For projects and listings: 3 × 5 × 2 = 30 cells per entity. The
  table is built once per BILLING_ENFORCED state; the cells are the
  rows. We assert each cell with a focused test name that names
  the row so a CI failure prints e.g. "past / active / false —
  Project" — the predicate matrix the §5.13 spec requires.

  For developers: 3 × 2 = 6 cells (no subscription axis; the
  developer itself is not billing-gated per §5.13).

  ## Why this test file exists

  §5.13 says "No second definition anywhere." The matrix is the
  grep-able contract. Any caller that needs the publish filter
  composes `Catalog.published/1`. If a new caller introduces a
  parallel `where: p.published_at <= ^now` clause, that test must
  explain why the §15.1 matrix doesn't already cover the case.
  """

  use Immo.DataCase, async: false

  # async: false because the tests share a process-wide compile-time
  # flag (`:immo, :billing_enforced`) that's set per-test via
  # `Application.put_env` and recompiled-read. Running concurrently
  # would race the recompile.

  alias Immo.Catalog
  alias Immo.Billing.Subscription
  alias Immo.Catalog.{Developer, Listing, Project, PropertyType}

  import Ecto.Query, only: [from: 2, where: 2]

  defp past, do: DateTime.utc_now(:second) |> DateTime.add(-3600, :second)
  defp future, do: DateTime.utc_now(:second) |> DateTime.add(3600, :second)

  defp developer_fixture(label, slug) do
    {:ok, _user} =
      Immo.Accounts.register_staff_user(%{
        email: "#{label}@example.com",
        password: "Test!Pass!2026",
        role: :admin
      })

    {:ok, developer} =
      Catalog.create_developer(%{
        name: label,
        slug: slug
      })

    developer
  end

  defp subscription_fixture(developer_id, status)
       when status in ["active", "trialing", "past_due", "canceled"] do
    {:ok, sub} =
      %Subscription{
        developer_id: developer_id,
        plan: "basic",
        status: status,
        provider: "manual",
        current_period_start: DateTime.utc_now(:second),
        current_period_end: DateTime.utc_now(:second) |> DateTime.add(30, :day),
        cancel_at_period_end: false
      }
      |> Immo.Repo.insert()

    sub
  end

  defp subscription_fixture(_, _), do: nil

  defp publish!(%Project{} = project, dt) do
    project
    |> Ecto.Changeset.change(%{published_at: dt})
    |> Immo.Repo.update!()
  end

  defp publish!(%Listing{} = listing, dt) do
    listing
    |> Ecto.Changeset.change(%{published_at: dt})
    |> Immo.Repo.update!()
  end

  defp publish!(%Developer{} = dev, dt) do
    dev
    |> Ecto.Changeset.change(%{published_at: dt})
    |> Immo.Repo.update!()
  end

  # The §15.1 matrix for projects.
  for billing_enforced <- [false, true] do
    for {sub_label, sub_status} <- [
          {"none", :none},
          {"trialing", "trialing"},
          {"active", "active"},
          {"past_due", "past_due"},
          {"canceled", "canceled"}
        ] do
      for {pa_label, pa_value} <- [
            {"null", nil},
            {"future", :future},
            {"past", :past}
          ] do
        expected =
          cond do
            pa_value in [nil, :future] -> :excluded
            billing_enforced and sub_status in [:none, "past_due", "canceled"] -> :excluded
            true -> :included
          end

        test "project / published_at=#{pa_label} / subscription=#{sub_label} / BILLING_ENFORCED=#{billing_enforced} → #{expected}" do
          run_project_matrix(
            unquote(billing_enforced),
            unquote(pa_value),
            unquote(sub_status),
            unquote(expected)
          )
        end
      end
    end
  end

  # The §15.1 matrix for listings.
  for billing_enforced <- [false, true] do
    for {sub_label, sub_status} <- [
          {"none", :none},
          {"trialing", "trialing"},
          {"active", "active"},
          {"past_due", "past_due"},
          {"canceled", "canceled"}
        ] do
      for {pa_label, pa_value} <- [
            {"null", nil},
            {"future", :future},
            {"past", :past}
          ] do
        expected =
          cond do
            pa_value in [nil, :future] -> :excluded
            billing_enforced and sub_status in [:none, "past_due", "canceled"] -> :excluded
            true -> :included
          end

        test "listing / published_at=#{pa_label} / subscription=#{sub_label} / BILLING_ENFORCED=#{billing_enforced} → #{expected}" do
          run_listing_matrix(
            unquote(billing_enforced),
            unquote(pa_value),
            unquote(sub_status),
            unquote(expected)
          )
        end
      end
    end
  end

  # The §15.1 matrix for developers. No subscription axis; the
  # developer is not billing-gated per §5.13.
  for billing_enforced <- [false, true] do
    for {pa_label, pa_value} <- [
          {"null", nil},
          {"future", :future},
          {"past", :past}
        ] do
      expected = if pa_value == :past, do: :included, else: :excluded

      test "developer / published_at=#{pa_label} / BILLING_ENFORCED=#{billing_enforced} → #{expected}" do
        with_billing_flag(unquote(billing_enforced), fn ->
          slug =
            "dev-#{unquote(pa_label)}-#{unquote(billing_enforced)}-#{System.unique_integer([:positive])}"

          dev = developer_fixture("dev-#{unquote(pa_label)}-#{unquote(billing_enforced)}", slug)

          dev =
            case unquote(pa_value) do
              :past -> publish!(dev, past())
              :future -> publish!(dev, future())
              nil -> dev
            end

          results = Developer |> Catalog.published() |> Immo.Repo.all()
          listed? = dev.id in Enum.map(results, & &1.id)

          assert listed? == (unquote(expected) == :included),
                 "expected developer to be #{unquote(expected)} but got listed?=#{listed?}"
        end)
      end
    end
  end

  describe "composability (§5.13 single-definition contract)" do
    test "caller can layer additional where/select on top" do
      with_billing_flag(false, fn ->
        slug = "comp-#{System.unique_integer([:positive])}"
        dev = developer_fixture("comp", slug)

        {:ok, project_casa} =
          Catalog.create_project(%{
            developer_id: dev.id,
            title: %{"fr" => "P"},
            slug: "#{slug}-casa",
            city: "Casa"
          })

        {:ok, project_rabat} =
          Catalog.create_project(%{
            developer_id: dev.id,
            title: %{"fr" => "P2"},
            slug: "#{slug}-rabat",
            city: "Rabat"
          })

        project_casa = publish!(project_casa, past())
        _project_rabat = publish!(project_rabat, past())

        results =
          Project
          |> Catalog.published()
          |> where(city: "Casa")
          |> Immo.Repo.all()

        assert [%Project{id: matched_id}] = results
        assert matched_id == project_casa.id
      end)
    end

    test "passes through an existing %Ecto.Query{} with a known source" do
      with_billing_flag(false, fn ->
        slug = "passthrough-#{System.unique_integer([:positive])}"
        dev = developer_fixture("Passthrough", slug)

        {:ok, project} =
          Catalog.create_project(%{developer_id: dev.id, title: %{"fr" => "P"}, slug: slug})

        project = publish!(project, past())

        q = from(p in Project, where: is_nil(p.city))
        result = q |> Catalog.published() |> Immo.Repo.all()

        assert [%Project{id: matched_id}] = result
        assert matched_id == project.id
      end)
    end

    test "raises on unknown query source (fail-closed)" do
      # An Ecto.Query whose source is a schema we don't recognize
      # as one of the §5.13 publish subjects must raise — not
      # silently bypass the predicate.
      q = from(p in PropertyType, select: p.id)

      assert_raise ArgumentError, ~r/only supports Developer, Project, and Listing/, fn ->
        Catalog.published(q)
      end
    end
  end

  ## Matrix runners

  defp run_project_matrix(billing_enforced, pa_value, sub_status, expected) do
    with_billing_flag(billing_enforced, fn ->
      slug = "proj-#{System.unique_integer([:positive])}"
      dev = developer_fixture("proj-#{slug}", slug)

      _sub = if sub_status != :none, do: subscription_fixture(dev.id, sub_status)

      {:ok, project} =
        Catalog.create_project(%{developer_id: dev.id, title: %{"fr" => "P"}, slug: slug})

      project =
        case pa_value do
          :past -> publish!(project, past())
          :future -> publish!(project, future())
          nil -> project
        end

      results = Project |> Catalog.published() |> Immo.Repo.all()
      listed? = project.id in Enum.map(results, & &1.id)

      assert listed? == (expected == :included),
             "expected project to be #{expected} but got listed?=#{listed?}"
    end)
  end

  defp run_listing_matrix(billing_enforced, pa_value, sub_status, expected) do
    with_billing_flag(billing_enforced, fn ->
      slug = "list-#{System.unique_integer([:positive])}"
      dev = developer_fixture("list-#{slug}", slug)

      _sub = if sub_status != :none, do: subscription_fixture(dev.id, sub_status)

      {:ok, pt} =
        Catalog.create_property_type(%{
          key: "apt-#{System.unique_integer([:positive])}",
          label: %{"fr" => "A"},
          url_segment: %{"fr" => "a"},
          position: 0
        })

      {:ok, project} =
        Catalog.create_project(%{
          developer_id: dev.id,
          title: %{"fr" => "P"},
          slug: "#{slug}-proj"
        })

      {:ok, listing} =
        Catalog.create_listing(%{
          property_type_id: pt.id,
          project_id: project.id,
          title: %{"fr" => "L"},
          slug: slug
        })

      listing =
        case pa_value do
          :past -> publish!(listing, past())
          :future -> publish!(listing, future())
          nil -> listing
        end

      results = Listing |> Catalog.published() |> Immo.Repo.all()
      listed? = listing.id in Enum.map(results, & &1.id)

      assert listed? == (expected == :included),
             "expected listing to be #{expected} but got listed?=#{listed?}"
    end)
  end

  ## Billing-flag toggle

  # The billing flag is read at compile time. We force a recompile
  # of the catalog module via `Code.compile_string` so the new flag
  # value takes effect within the same test run. The catalog module
  # reads `:immo, :billing_enforced` via `Application.compile_env` at
  # compile time; recompiling the module picks up the freshly-set
  # value.
  defp with_billing_flag(value, fun) do
    # `Immo.Catalog.billing_enforced?/0` reads at runtime, so the
    # set-env / call-test / restore-env pattern is enough — no
    # recompile needed (P1-E2.3 ships the flag as a runtime knob so
    # production can flip it without redeploying).
    Application.put_env(:immo, :billing_enforced, value)
    fun.()
  after
    Application.put_env(:immo, :billing_enforced, false)
  end
end
