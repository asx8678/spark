# P1-E2.6 — Index verification via EXPLAIN (ANALYZE)

Per §16 P1-E2 AC: "EXPLAIN evidence attached: GIN jsonb_path_ops index scan for an
attributes containment query AND partial published index usage for a published-only
scan."

## Setup

Seed 42 listings (16 apt + 14 land + 12 rental) via `Immo.CatalogSeeds.run/0`.

The test volume is small (42 rows), so the PostgreSQL planner picks a
**Seq Scan** for both queries by default — at this size, scanning the
whole table is faster than going through an index. To demonstrate the
index path the planner **would** use at production scale, we force it
with `SET LOCAL enable_seqscan = OFF` inside a transaction.

The production query path (`Catalog.published/1` + `attributes @>` filters
on the search island) does not disable seqscan; the planner naturally
switches to the GIN/partial indexes once the table grows past a few
hundred rows. This evidence is to prove the index is **available** and
**usable** for the relevant predicates.

## Reproducing

```bash
cd newprojects/backend
MIX_ENV=test mix ecto.reset
MIX_ENV=test mix run -e 'Immo.CatalogSeeds.run()'
MIX_ENV=test mix run scripts/explain_indexes.exs
```

Or as a test (skipped by default to avoid sandbox quirks — run explicitly):

```bash
MIX_ENV=test mix test test/immo/catalog_seeds_test.exs:220  # GIN
MIX_ENV=test mix test test/immo/catalog_seeds_test.exs:240  # partial
```

## Evidence

### Query 1 — attributes containment (GIN jsonb_path_ops)

```sql
SELECT id FROM listings
WHERE attributes @> '{"bedrooms": 2}'::jsonb;
```

**Plan (seqscan disabled, 42 rows, ANALYZE on):**

```
Bitmap Heap Scan on listings  (cost=12.81..25.88 rows=5 width=16)
  (actual time=0.014..0.018 rows=9.00 loops=1)
  Recheck Cond: (attributes @> '{"bedrooms": 2}'::jsonb)
  Heap Blocks: exact=10
  Buffers: shared hit=13
  ->  Bitmap Index Scan on listings_attributes_gin
        (cost=0.00..12.81 rows=5 width=0)
        (actual time=0.009..0.009 rows=25.00 loops=1)
        Index Cond: (attributes @> '{"bedrooms": 2}'::jsonb)
        Index Searches: 1
        Buffers: shared hit=3
Planning Time: 0.039 ms
Execution Time: 0.025 ms
```

**Index used: `listings_attributes_gin`** (the `jsonb_path_ops` GIN
index from migration `20260610200003_create_listings.exs:69`).

### Query 2 — published-only scan (partial index)

```sql
SELECT id FROM listings
WHERE published_at IS NOT NULL;
```

**Plan (seqscan disabled, 42 rows, ANALYZE on):**

```
Index Scan using listings_published_partial_idx on listings
  (cost=0.14..27.57 rows=29 width=16)
  (actual time=0.005..0.008 rows=29.00 loops=1)
  Index Searches: 1
  Buffers: shared hit=15
Planning Time: 0.021 ms
Execution Time: 0.010 ms
```

**Index used: `listings_published_partial_idx`** (the `WHERE
published_at IS NOT NULL` partial index from migration
`20260610200003_create_listings.exs:83`). This is the index that
powers `Catalog.published/1` (§5.13) and the sitemap endpoint.

### Query 3 — combined (the realistic search query)

```sql
SELECT id FROM listings
WHERE published_at IS NOT NULL
  AND attributes @> '{"bedrooms": 2}'::jsonb;
```

**Plan (seqscan disabled, 42 rows, ANALYZE on):**

```
Bitmap Heap Scan on listings  (cost=12.81..25.88 rows=3 width=16)
  (actual time=0.010..0.014 rows=7.00 loops=1)
  Recheck Cond: (attributes @> '{"bedrooms": 2}'::jsonb)
  Filter: (published_at IS NOT NULL)
  Rows Removed by Filter: 2
  Heap Blocks: exact=10
  Buffers: shared hit=13
  ->  Bitmap Index Scan on listings_attributes_gin
        (cost=0.00..12.81 rows=5 width=0)
        (actual time=0.006..0.007 rows=25.00 loops=1)
        Index Cond: (attributes @> '{"bedrooms": 2}'::jsonb)
        Index Searches: 1
        Buffers: shared hit=3
Planning Time: 0.026 ms
Execution Time: 0.017 ms
```

The combined query uses the GIN index for the containment filter and
applies the published filter as a Bitmap Heap recheck. This is the
expected behavior — at production scale, the planner will combine both
indexes via BitmapOr when selectivity is favorable.

## Index definitions

From `priv/repo/migrations/20260610200003_create_listings.exs`:

```elixir
# §5.4: GIN on attributes with jsonb_path_ops (smaller, supports @@ only)
"CREATE INDEX listings_attributes_gin ON listings USING GIN (attributes jsonb_path_ops)"

# §5.4: partial index for published rows
create index(:listings, [:published_at],
         where: "published_at IS NOT NULL",
         name: "listings_published_partial_idx"
       )
```

## Conclusion

Both required indexes (`listings_attributes_gin` GIN and
`listings_published_partial_idx` partial) are present and used by the
planner for the relevant predicates. At production scale (thousands
of listings), these are the indexes that will power:
  * `Catalog.published/1` and the sitemap (§5.13)
  * Property-type facet search (apartment/land/rental with price,
    surface, bedrooms, energy-class, zoning filters)
  * Frontend filter island (Phase 2)
