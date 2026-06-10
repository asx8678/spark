defmodule ImmoWeb.Api.ResponseShape do
  @moduledoc """
  §6.3 — `{data, meta}` envelope for the `/api/v1` build-tier list
  endpoints.

  The build loader consumes this envelope to extract the records
  and the next-page cursor. The `meta` block carries pagination
  state plus any per-endpoint summary (count, etc.).
  """

  alias ImmoWeb.Api.Pagination

  @doc """
  Build a `{data, meta}` envelope from a `Pagination.t()`.

  The `data` array is the records (already truncated to `limit` by
  `Pagination.fetch_all/1`) shaped by the per-endpoint `shape_fn`.

  The `meta` block includes:
    * `count` — the number of records in this page
    * `next_cursor` — opaque cursor for the next page, or `nil`
  """
  @spec envelope(Pagination.t(), (map() -> map())) :: %{data: [map()], meta: map()}
  def envelope(%Pagination{} = page, shape_fn) do
    %{
      data: Enum.map(page.records, shape_fn),
      meta: %{
        count: page.count,
        next_cursor: page.next_cursor
      }
    }
  end
end
