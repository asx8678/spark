defmodule Immo.ContextsTest do
  @moduledoc """
  P1-E2.5 — context skeleton tests.

  Coverage:
    * Each context module's public functions exist with `@spec`
      annotations (P1-E4 / P1-E6 / P3 / P4 / P6 implement against
      the agreed signatures).
    * Base changesets enforce field-level invariants (FKs, enums,
      defaults) — the contract the future cross-context callers
      rely on.
    * Boundary check: Catalog does NOT own the §5.6/§5.7/§5.9/§5.10
      tables; the schema modules are reachable from their owning
      context, not from Catalog.

  We deliberately don't introspect `@moduledoc` content here —
  Elixir doesn't keep the source string in BEAM bytecode, so
  asserting on moduledoc text would require parsing source files.
  The moduledoc text is reviewed in code review; the runtime
  contract is the public function surface + changeset invariants.
  """

  use ExUnit.Case, async: true

  alias Immo.Catalog.Developer
  alias Immo.CRM.Inquiry
  alias Immo.Billing.{Payment, Subscription}
  alias Immo.Edge.{Build, Paths}
  alias Immo.Media.Media

  describe "each context has typespec'd public functions (P1-E4 / P1-E6 / P3 / P4 / P6 implement against these)" do
    test "Immo.Media.get_media!/1 has a typespec" do
      assert {:ok, specs} = Code.Typespec.fetch_specs(Immo.Media)
      assert is_list(specs)
      assert Enum.any?(specs, &match?({{:get_media!, _}, _}, &1))
    end

    test "Immo.Media.list_media_for/2 has a typespec" do
      assert {:ok, specs} = Code.Typespec.fetch_specs(Immo.Media)
      assert Enum.any?(specs, &match?({{:list_media_for, _}, _}, &1))
    end

    test "Immo.Media.create_media/2 has a typespec" do
      assert {:ok, specs} = Code.Typespec.fetch_specs(Immo.Media)
      assert Enum.any?(specs, &match?({{:create_media, _}, _}, &1))
    end

    test "Immo.CRM.get_inquiry!/1 has a typespec" do
      assert {:ok, specs} = Code.Typespec.fetch_specs(Immo.CRM)
      assert Enum.any?(specs, &match?({{:get_inquiry!, _}, _}, &1))
    end

    test "Immo.CRM.create_inquiry/2 has a typespec" do
      assert {:ok, specs} = Code.Typespec.fetch_specs(Immo.CRM)
      assert Enum.any?(specs, &match?({{:create_inquiry, _}, _}, &1))
    end

    test "Immo.Billing.get_subscription!/1 has a typespec" do
      assert {:ok, specs} = Code.Typespec.fetch_specs(Immo.Billing)
      assert Enum.any?(specs, &match?({{:get_subscription!, _}, _}, &1))
    end

    test "Immo.Billing.create_subscription/2 has a typespec" do
      assert {:ok, specs} = Code.Typespec.fetch_specs(Immo.Billing)
      assert Enum.any?(specs, &match?({{:create_subscription, _}, _}, &1))
    end

    test "Immo.Billing.get_payment!/1 has a typespec" do
      assert {:ok, specs} = Code.Typespec.fetch_specs(Immo.Billing)
      assert Enum.any?(specs, &match?({{:get_payment!, _}, _}, &1))
    end

    test "Immo.Billing.create_payment/2 has a typespec" do
      assert {:ok, specs} = Code.Typespec.fetch_specs(Immo.Billing)
      assert Enum.any?(specs, &match?({{:create_payment, _}, _}, &1))
    end

    test "Immo.Edge.get_build!/1 has a typespec" do
      assert {:ok, specs} = Code.Typespec.fetch_specs(Immo.Edge)
      assert Enum.any?(specs, &match?({{:get_build!, _}, _}, &1))
    end

    test "Immo.Edge.create_build/2 has a typespec" do
      assert {:ok, specs} = Code.Typespec.fetch_specs(Immo.Edge)
      assert Enum.any?(specs, &match?({{:create_build, _}, _}, &1))
    end

    test "Immo.Edge.Paths.path_for/1 has a typespec" do
      assert {:ok, specs} = Code.Typespec.fetch_specs(Immo.Edge.Paths)
      assert Enum.any?(specs, &match?({{:path_for, _}, _}, &1))
    end
  end

  describe "Immo.Media.Media — base changeset invariants (§5.6)" do
    test "rejects unknown attachable_type" do
      cs =
        Media.create_changeset(%Media{}, %{
          attachable_type: "Snake",
          attachable_id: Ecto.UUID.generate(),
          kind: "photo",
          r2_key: "media/x/y/z.jpg"
        })

      assert %{attachable_type: ["is invalid"]} = errors_on(cs)
    end

    test "rejects unknown kind" do
      cs =
        Media.create_changeset(%Media{}, %{
          attachable_type: "Project",
          attachable_id: Ecto.UUID.generate(),
          kind: "weird",
          r2_key: "media/x/y/z.jpg"
        })

      assert %{kind: ["is invalid"]} = errors_on(cs)
    end

    test "accepts valid attachable_type + kind + r2_key" do
      cs =
        Media.create_changeset(%Media{}, %{
          attachable_type: "Project",
          attachable_id: Ecto.UUID.generate(),
          kind: "photo",
          r2_key: "media/Project/abc/sha.jpg"
        })

      assert cs.valid?
    end

    test "rejects r2_key without a path separator" do
      cs =
        Media.create_changeset(%Media{}, %{
          attachable_type: "Project",
          attachable_id: Ecto.UUID.generate(),
          kind: "photo",
          r2_key: "noslash"
        })

      assert %{r2_key: [_]} = errors_on(cs)
    end

    test "rejects r2_key without a file extension" do
      cs =
        Media.create_changeset(%Media{}, %{
          attachable_type: "Project",
          attachable_id: Ecto.UUID.generate(),
          kind: "photo",
          r2_key: "media/x/y/z"
        })

      assert %{r2_key: [_]} = errors_on(cs)
    end

    test "default position is 0" do
      cs =
        Media.create_changeset(%Media{}, %{
          attachable_type: "Project",
          attachable_id: Ecto.UUID.generate(),
          kind: "photo",
          r2_key: "media/x/y/z.jpg"
        })

      assert Ecto.Changeset.apply_changes(cs).position == 0
    end

    test "attachable_types/0 lists the §5.6 polymorphic set" do
      assert Media.attachable_types() == ["Project", "Listing", "Developer"]
    end

    test "kinds/0 lists the §5.6 kind set" do
      assert Enum.sort(Media.kinds()) == Enum.sort(~w(photo floorplan brochure document logo))
    end
  end

  describe "Immo.CRM.Inquiry — base changeset invariants (§5.7)" do
    test "rejects missing consent (Law 09-08)" do
      cs =
        Inquiry.create_changeset(%Inquiry{}, %{name: "X", email: "x@example.com", message: "hi"})

      assert %{consent: [_]} = errors_on(cs)
    end

    test "rejects missing required fields" do
      cs = Inquiry.create_changeset(%Inquiry{}, %{consent: true})
      assert %{name: [_], email: [_], message: [_]} = errors_on(cs)
    end

    test "rejects bad email format" do
      cs =
        Inquiry.create_changeset(%Inquiry{}, %{
          name: "X",
          email: "not-an-email",
          message: "hi",
          consent: true
        })

      assert %{email: [_]} = errors_on(cs)
    end

    test "rejects unknown status" do
      cs =
        Inquiry.create_changeset(%Inquiry{}, %{
          name: "X",
          email: "x@example.com",
          message: "hi",
          consent: true,
          status: "deleted"
        })

      assert %{status: ["is invalid"]} = errors_on(cs)
    end

    test "accepts a valid inquiry" do
      cs =
        Inquiry.create_changeset(%Inquiry{}, %{
          name: "Buyer",
          email: "buyer@example.com",
          message: "Interested in apartment",
          consent: true
        })

      assert cs.valid?
    end

    test "default status is 'new'" do
      cs =
        Inquiry.create_changeset(%Inquiry{}, %{
          name: "X",
          email: "x@example.com",
          message: "hi",
          consent: true
        })

      assert Ecto.Changeset.apply_changes(cs).status == "new"
    end

    test "statuses/0 lists the §5.7 status set" do
      assert Inquiry.statuses() == ~w(new contacted closed)
    end
  end

  describe "Immo.Billing.Subscription — base changeset invariants (§5.9)" do
    test "rejects unknown plan" do
      cs =
        Subscription.create_changeset(%Subscription{}, %{
          developer_id: Ecto.UUID.generate(),
          plan: "platinum",
          status: "active",
          provider: "manual"
        })

      assert %{plan: ["is invalid"]} = errors_on(cs)
    end

    test "rejects unknown status" do
      cs =
        Subscription.create_changeset(%Subscription{}, %{
          developer_id: Ecto.UUID.generate(),
          plan: "basic",
          status: "expired",
          provider: "manual"
        })

      assert %{status: ["is invalid"]} = errors_on(cs)
    end

    test "rejects unknown provider" do
      cs =
        Subscription.create_changeset(%Subscription{}, %{
          developer_id: Ecto.UUID.generate(),
          plan: "basic",
          status: "active",
          provider: "paypal"
        })

      assert %{provider: ["is invalid"]} = errors_on(cs)
    end

    test "rejects current_period_end before current_period_start" do
      start_at = DateTime.utc_now(:second) |> DateTime.add(7, :day)
      end_at = DateTime.utc_now(:second) |> DateTime.add(-1, :day)

      cs =
        Subscription.create_changeset(%Subscription{}, %{
          developer_id: Ecto.UUID.generate(),
          plan: "basic",
          status: "active",
          provider: "manual",
          current_period_start: start_at,
          current_period_end: end_at
        })

      assert %{current_period_end: [_]} = errors_on(cs)
    end

    test "plans/0 + statuses/0 + providers/0 list the §5.9 allowlist" do
      assert Subscription.plans() == ~w(basic featured enterprise)
      assert Subscription.statuses() == ~w(trialing active past_due canceled)
      assert Subscription.providers() == ~w(stripe cmi manual)
    end
  end

  describe "Immo.Billing.Payment — base changeset invariants (§5.9)" do
    test "rejects non-positive amount" do
      cs =
        Payment.create_changeset(%Payment{}, %{
          subscription_id: Ecto.UUID.generate(),
          amount: 0,
          currency: "MAD",
          status: "pending",
          provider: "manual"
        })

      assert %{amount: [_]} = errors_on(cs)
    end

    test "rejects non-3-letter currency" do
      cs =
        Payment.create_changeset(%Payment{}, %{
          subscription_id: Ecto.UUID.generate(),
          amount: 100,
          currency: "DOLLAR",
          status: "pending",
          provider: "manual"
        })

      errors = errors_on(cs)
      assert errors.currency != []
    end

    test "rejects lowercase currency" do
      cs =
        Payment.create_changeset(%Payment{}, %{
          subscription_id: Ecto.UUID.generate(),
          amount: 100,
          currency: "mad",
          status: "pending",
          provider: "manual"
        })

      errors = errors_on(cs)
      assert errors.currency != []
    end

    test "rejects unknown status / provider" do
      cs =
        Payment.create_changeset(%Payment{}, %{
          subscription_id: Ecto.UUID.generate(),
          amount: 100,
          currency: "MAD",
          status: "void",
          provider: "manual"
        })

      assert %{status: ["is invalid"]} = errors_on(cs)
    end

    test "statuses/0 + providers/0 list the §5.9 allowlist" do
      assert Payment.statuses() == ~w(pending succeeded failed refunded)
      assert Payment.providers() == ~w(stripe cmi manual)
    end
  end

  describe "Immo.Edge.Build — base changeset invariants (§5.10)" do
    test "rejects unknown status" do
      cs = Build.create_changeset(%Build{}, %{trigger: "manual", status: "aborted"})
      assert %{status: ["is invalid"]} = errors_on(cs)
    end

    test "rejects unknown trigger" do
      cs = Build.create_changeset(%Build{}, %{trigger: "github_action"})
      assert %{trigger: ["is invalid"]} = errors_on(cs)
    end

    test "accepts a minimal queued/cron build" do
      cs = Build.create_changeset(%Build{}, %{trigger: "cron", status: "queued"})
      assert cs.valid?
    end

    test "default status is 'queued'" do
      cs = Build.create_changeset(%Build{}, %{trigger: "cron"})
      assert Ecto.Changeset.apply_changes(cs).status == "queued"
    end

    test "transition_changeset/3 updates status to a valid value" do
      cs = Build.transition_changeset(%Build{status: "queued"}, "running", %{})
      assert cs.valid?
      assert Ecto.Changeset.apply_changes(cs).status == "running"
    end

    test "transition_changeset/3 rejects an unknown status" do
      cs = Build.transition_changeset(%Build{status: "queued"}, "aborted", %{})
      assert %{status: ["is invalid"]} = errors_on(cs)
    end

    test "statuses/0 + triggers/0 list the §5.10 allowlist" do
      assert Build.statuses() == ~w(queued running succeeded failed skipped)
      assert Build.triggers() == ~w(cron manual)
    end
  end

  describe "Immo.Edge.Paths (P1-E5.2 single path authority)" do
    test "path_for/2 is the dispatching entry point (no /1 exists)" do
      refute function_exported?(Paths, :path_for, 1),
             "Immo.Edge.Paths.path_for must take a locale (path_for/2). " <>
               "The §6.3 contract is per-locale paths; the locale is not optional."
    end

    test "path_for/2 on an unknown record returns '/' (stable fallback, not a crash)" do
      assert Paths.path_for(%{}, :fr) == "/"
    end
  end

  describe "§6.1 boundary — Catalog does NOT own §5.6/§5.7/§5.9/§5.10 tables" do
    test "Immo.Catalog has no Media schema (moved to Immo.Media.Media)" do
      refute Code.ensure_loaded?(Immo.Catalog.Media),
             "Immo.Catalog.Media should not exist; Media is owned by Immo.Media per §6.1"
    end

    test "Immo.Catalog has no Inquiry schema (owned by Immo.CRM)" do
      refute Code.ensure_loaded?(Immo.Catalog.Inquiry),
             "Immo.Catalog.Inquiry should not exist; Inquiry is owned by Immo.CRM per §6.1"
    end

    test "Immo.Catalog has no Subscription schema (owned by Immo.Billing)" do
      refute Code.ensure_loaded?(Immo.Catalog.Subscription),
             "Immo.Catalog.Subscription should not exist; Subscription is owned by Immo.Billing per §6.1"
    end

    test "Immo.Catalog has no Payment schema (owned by Immo.Billing)" do
      refute Code.ensure_loaded?(Immo.Catalog.Payment),
             "Immo.Catalog.Payment should not exist; Payment is owned by Immo.Billing per §6.1"
    end

    test "Immo.Catalog has no Build schema (owned by Immo.Edge)" do
      refute Code.ensure_loaded?(Immo.Catalog.Build),
             "Immo.Catalog.Build should not exist; Build is owned by Immo.Edge per §6.1"
    end

    test "Developer.logo_media references Immo.Media.Media (not Immo.Catalog.Media)" do
      assert Developer.__schema__(:association, :logo_media).related == Immo.Media.Media
    end
  end

  ## helpers

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
