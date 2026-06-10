defmodule Immo.CatalogSeedsTest do
  @moduledoc """
  P1-E2.6 — Seed module surface tests.

  Verifies the `Immo.CatalogSeeds` module is loadable and exposes the
  documented public API. The full seed execution is exercised by
  `mix run priv/repo/seeds.exs` (the CI AC) and documented in
  `docs/infra/seed-explain-evidence.md`. Running the seed inside the
  test sandbox would conflict with other Catalog tests that hardcode
  `key: "apartment"` in their setup, so we keep this test purely
  structural.
  """

  use ExUnit.Case, async: true

  test "module is loadable" do
    assert Code.ensure_loaded?(Immo.CatalogSeeds)
  end

  test "exposes run/0, seeded?/0, reset!/0" do
    # `Code.ensure_loaded!` forces the load in async contexts;
    # `function_exported?` alone is racy against the module's
    # first-call lazy load.
    Code.ensure_loaded!(Immo.CatalogSeeds)
    funcs = Immo.CatalogSeeds.__info__(:functions) |> Enum.map(&elem(&1, 0))
    assert :run in funcs
    assert :seeded? in funcs
    assert :reset! in funcs
  end

  test "run/0 exists" do
    # Same race fix as above; the structural check is the
    # important bit (the function lives in the module).
    Code.ensure_loaded!(Immo.CatalogSeeds)
    assert function_exported?(Immo.CatalogSeeds, :run, 0)
  end
end
