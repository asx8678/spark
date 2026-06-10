Immo.CatalogSeeds.reset!()
Immo.CatalogSeeds.run()

# SET LOCAL only works inside a transaction
{:ok, _} =
  Immo.Repo.transact(fn ->
    _ = Immo.Repo.query!("SET LOCAL enable_seqscan = OFF")

    result_gin =
      Immo.Repo.query!("""
      EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
      SELECT id FROM listings
      WHERE attributes @> '{"bedrooms": 2}'::jsonb
      """)

    IO.puts("===== GIN jsonb_path_ops containment (force index) =====")
    Enum.each(result_gin.rows, fn [line] -> IO.puts(line) end)

    result_partial =
      Immo.Repo.query!("""
      EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
      SELECT id FROM listings
      WHERE published_at IS NOT NULL
      """)

    IO.puts("\n===== Partial published index (force index) =====")
    Enum.each(result_partial.rows, fn [line] -> IO.puts(line) end)

    result_combo =
      Immo.Repo.query!("""
      EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
      SELECT id FROM listings
      WHERE published_at IS NOT NULL
        AND attributes @> '{"bedrooms": 2}'::jsonb
      """)

    IO.puts("\n===== Combined (force index) =====")
    Enum.each(result_combo.rows, fn [line] -> IO.puts(line) end)

    {:ok, :done}
  end)
