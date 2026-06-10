defmodule ImmoWeb.Api.Pagination do
  @moduledoc """
  §6.3 — Cursor pagination for the `/api/v1` build-tier lists.

  Cursor-based keyset pagination over `id` (UUID v7) for stability
  across concurrent writes: a record inserted mid-page does not
  shift existing records' positions, and the `since` filter on
  `updated_at` composes cleanly with the cursor.

  ## Usage

      page =
        Pagination.from_params(params, default_limit: 50, max_limit: 100)
        |> Pagination.apply(&Catalog.list_published_projects/1)
        |> Pagination.fetch_all()

      # page.records → [Project.t(), ...]
      # page.count → integer (records in this page)
      # page.next_cursor → binary() | nil

  ## Params

    * `limit`  — integer; clamped to `[1, max_limit]`.
    * `cursor` — base64-encoded `id` of the last record from the
      previous page. Opaque to the client.
    * `since`  — ISO-8601 timestamp string. Records with
      `updated_at > since` only.

  ## Stability

  The cursor encodes a single UUID (the last record's `id`). The
  next page is `WHERE id > ^cursor ORDER BY id ASC LIMIT limit+1`.
  We fetch `limit + 1` so we can detect "is there another page?".
  If the +1th record exists, the actual page is truncated and the
  `next_cursor` is the last record's id; otherwise `next_cursor` is
  nil (end of dataset).
  """

  defstruct [:limit, :cursor_id, :since, records: [], count: 0, next_cursor: nil]

  @type t :: %__MODULE__{
          limit: pos_integer(),
          cursor_id: String.t() | nil,
          since: DateTime.t() | nil,
          records: [map()],
          count: non_neg_integer(),
          next_cursor: String.t() | nil
        }

  @doc "Build a pagination opts struct from request params."
  @spec from_params(map(), keyword()) :: t()
  def from_params(params, opts) do
    default_limit = Keyword.get(opts, :default_limit, 50)
    max_limit = Keyword.get(opts, :max_limit, 100)

    %__MODULE__{
      limit: parse_limit(params["limit"], default_limit, max_limit),
      cursor_id: parse_cursor(params["cursor"]),
      since: parse_since(params["since"])
    }
  end

  @doc "Run a catalog list function with these pagination opts and capture records."
  @spec apply(t(), (keyword() -> [map()])) :: t()
  def apply(%__MODULE__{} = page, list_fn) do
    catalog_opts = [
      limit: page.limit,
      cursor_id: page.cursor_id,
      since: page.since
    ]

    page
    |> Map.put(:records, list_fn.(catalog_opts))
    |> Map.put(:count, length(page.records))
  end

  @doc "Compute `next_cursor` from the loaded records."
  @spec fetch_all(t()) :: t()
  def fetch_all(%__MODULE__{limit: limit, records: records} = page) do
    if length(records) > limit do
      # We fetched limit+1; the +1th tells us there's a next page.
      page_truncated = Enum.take(records, limit)
      next_cursor = encode_cursor(List.last(page_truncated))

      %{page | records: page_truncated, count: length(page_truncated), next_cursor: next_cursor}
    else
      %{page | next_cursor: nil}
    end
  end

  @doc "Encode a record's `id` as an opaque cursor string."
  @spec encode_cursor(map() | nil) :: String.t() | nil
  def encode_cursor(nil), do: nil
  def encode_cursor(%{id: id}) when is_binary(id), do: Base.encode64(id, padding: false)
  def encode_cursor(_), do: nil

  @doc "Decode a cursor back to its underlying id."
  @spec decode_cursor(String.t()) :: {:ok, String.t()} | {:error, :invalid}
  def decode_cursor(cursor) when is_binary(cursor) do
    case Base.decode64(cursor, padding: false) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid}
    end
  end

  ## Param parsers

  defp parse_limit(nil, default, _max), do: default
  defp parse_limit("", default, _max), do: default

  defp parse_limit(limit_str, default, max) when is_binary(limit_str) do
    case Integer.parse(limit_str) do
      {n, _} when n > 0 and n <= max -> n
      {n, _} when n > max -> max
      _ -> default
    end
  end

  defp parse_limit(_limit, default, _max), do: default

  defp parse_cursor(nil), do: nil
  defp parse_cursor(""), do: nil

  defp parse_cursor(cursor) when is_binary(cursor) do
    case decode_cursor(cursor) do
      {:ok, id} -> id
      {:error, :invalid} -> nil
    end
  end

  defp parse_since(nil), do: nil
  defp parse_since(""), do: nil

  defp parse_since(since_str) when is_binary(since_str) do
    case DateTime.from_iso8601(since_str) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end
end
