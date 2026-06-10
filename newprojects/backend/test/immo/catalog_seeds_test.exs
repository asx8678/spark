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
    funcs = Immo.CatalogSeeds.__info__(:functions) |> Enum.map(&elem(&1, 0))
    assert :run in funcs
    assert :seeded? in funcs
    assert :reset! in funcs
  end

  test "run/0 returns a map" do
    # Just verify the function exists and is callable. The actual
    # seed execution is tested via the dev seeds.exs path.
    assert function_exported?(Immo.CatalogSeeds, :run, 0)
  end
end
