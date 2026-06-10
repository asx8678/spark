defmodule Immo.Media do
  @moduledoc """
  Media context — §6.1 bounded responsibility.

  Owns:
    * `media` records (§5.6) — polymorphic attachments
      (Project / Listing / Developer).
    * Presigned R2 upload pipeline (P1-E4).
    * Derivative jobs (P1-E4) — Oban workers for thumbnails,
      blurhash, format negotiation.

  Out of scope for P1-E2.5 (the P1-E2.5 delivery is typespecs + base
  changesets only):
    * The actual upload pipeline (P1-E4).
    * Direct-to-R2 presign endpoint (P1-E4).
    * Derivative Oban workers (P1-E4).
  """

  alias Immo.Media.Media
  alias Immo.Repo

  import Ecto.Query, only: [from: 2]

  ## Public API (P1-E2.5 skeletons — P1-E4 fleshes out the body)

  @doc """
  Get a media record by id (raises if not found).
  """
  @spec get_media!(binary()) :: Media.t()
  def get_media!(id), do: Repo.get!(Media, id)

  @doc """
  Get a media record by r2_key. Returns nil if not found.
  """
  @spec get_media_by_r2_key(String.t()) :: Media.t() | nil
  def get_media_by_r2_key(r2_key) when is_binary(r2_key) do
    Repo.get_by(Media, r2_key: r2_key)
  end

  @doc """
  List media records for a given attachable (e.g. all photos for
  a Project). The composite index on
  `(attachable_type, attachable_id, position)` is what this query
  hits.
  """
  @spec list_media_for(atom() | String.t(), binary()) :: [Media.t()]
  def list_media_for(attachable_type, attachable_id) when is_binary(attachable_id) do
    type =
      case attachable_type do
        atom when is_atom(atom) ->
          atom |> Module.split() |> List.last() |> to_string()

        string when is_binary(string) ->
          string

        _ ->
          raise ArgumentError, "attachable_type must be an atom or a string"
      end

    from(m in Media,
      where: m.attachable_type == ^type and m.attachable_id == ^attachable_id,
      order_by: [asc: :position, asc: :inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Insert a new media record. The P1-E2.5 skeleton wraps the
  `create_changeset/2` in `Repo.transact/1` and writes the
  audit_log row via `Immo.Audit` (so the §5.12 / §13 audit-on-all-
  mutations invariant holds even for media). P1-E4 adds the
  presign-URL + derivative-job fire-and-forget on top.
  """
  @spec create_media(map(), keyword()) :: {:ok, Media.t()} | {:error, Ecto.Changeset.t()}
  def create_media(attrs, opts \\ []) do
    Repo.transact(fn ->
      with {:ok, media} <-
             %Media{} |> Media.create_changeset(attrs) |> Repo.insert(),
           :ok <-
             Immo.Audit.log_mutation(
               actor_user: opts[:actor_user],
               action: "create",
               entity: media,
               diff: Immo.Audit.create_diff(media)
             ) do
        {:ok, media}
      end
    end)
  end

  @doc """
  Delete a media record. Stubs out the actual delete for P1-E2.5
  (P1-E4 fleshes out R2 object deletion + derivative cleanup).

  Note: the §5.11 redirects path is NOT touched here — the
  `redirects` table is Catalog-owned (§6.1) and the
  record-presence invariant ("the same media file is served
  forever") is achieved at the edge via `redirects.json` (P1-E5.2)
  rather than at the DB.
  """
  @spec delete_media(Media.t(), keyword()) :: {:ok, Media.t()} | {:error, Ecto.Changeset.t()}
  def delete_media(media, opts \\ []) do
    Repo.transact(fn ->
      with {:ok, _} <- Repo.delete(media),
           :ok <-
             Immo.Audit.log_mutation(
               actor_user: opts[:actor_user],
               action: "delete",
               entity: media,
               diff: Immo.Audit.delete_diff(media)
             ) do
        {:ok, media}
      end
    end)
  end
end
