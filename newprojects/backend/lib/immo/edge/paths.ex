defmodule Immo.Edge.Paths do
  @moduledoc """
  §6.1 / §6.3 — **single path authority** for every public URL.

  Per §6.1, `Immo.Edge` owns "path computation" — the one and only
  place that turns a developer / project / listing / property_type
  record into a public URL. §15.1 makes this correctness-critical:
  the API `path` field and the Cloudflare KV key (P4) must always
  agree, and the only way that holds is a single function both
  sides call.

  P1-E5.2 ships v1: locale-aware paths from `url_segment` + city +
  slug per §5.3 / §7.1. v2 (P4-E4.1) hardens this with property
  tests.

  ## Route shapes (from §7.1)

      /promoteurs/{slug}                    developer
      /projets/{city}/{slug}                project (with `projets` per-locale)
      /{type_segment}/{city}/{slug}         listing (segment from url_segment)
      /                                     root (special: no record)

  Each function takes a record (`%Developer{}`, `%Project{}`,
  `%Listing{}`) and a locale (`:fr | :ar | :en`) and returns the
  per-locale canonical path. Slugs and city slugs are normalized
  for URL safety (lowercase, dashes for non-alphanumeric).

  ## Examples

      iex> Immo.Edge.Paths.path_for(%Developer{slug: "immo-atlas"}, :fr)
      "/promoteurs/immo-atlas"

      iex> Immo.Edge.Paths.path_for(
      ...>   %Project{slug: "le-jardin", city: "Casablanca"},
      ...>   :fr
      ...> )
      "/projets/casablanca/le-jardin"

      iex> Immo.Edge.Paths.path_for(
      ...>   %Listing{slug: "apt-casa-1"},
      ...>   :fr,
      ...>   property_type: %PropertyType{url_segment: %{"fr" => "appartements"}}
      ...> )
      "/appartements/casablanca/apt-casa-1"
  """

  @default_locale :fr
  @supported_locales [:fr, :ar, :en]

  # Hard-coded URL segments for the §7.1 routes. These are the
  # "promoteurs" / "projets" / etc. — the records themselves carry
  # the listing type segment via `url_segment` (per-locale).
  @developer_segment "promoteurs"
  @project_segment "projets"

  @doc """
  Compute the public URL path for a record in a given locale.

  Dispatches on the record's schema module. The fallback clause
  returns "/" so callers in non-canonical contexts (e.g. drafts
  with no property_type) get a stable, non-crashing default.

  Returns the path with a leading slash and no trailing slash.
  """
  @spec path_for(map(), atom()) :: String.t()
  def path_for(%Immo.Catalog.Developer{} = record, _locale) do
    "/" <> @developer_segment <> "/" <> normalize_slug(record.slug)
  end

  def path_for(%Immo.Catalog.Project{} = record, _locale) do
    "/" <>
      @project_segment <>
      "/" <>
      normalize_slug(record.city || "") <>
      "/" <>
      normalize_slug(record.slug)
  end

  def path_for(%Immo.Catalog.Listing{} = record, locale) do
    type_segment = listing_type_segment(record, locale)
    city_slug = normalize_slug(record.city || "")

    "/" <>
      type_segment <>
      "/" <>
      city_slug <>
      "/" <>
      normalize_slug(record.slug)
  end

  # A property_type page is the index for a given type — e.g.
  # `/appartements` lists all apartments. The path is just the
  # locale-resolved `url_segment`.
  def path_for(%Immo.Catalog.PropertyType{} = record, locale) do
    "/" <> type_segment_for(record, locale)
  end

  def path_for(_record, _locale), do: "/"

  @doc """
  Compute paths in every supported locale for a single record.

  Returns a map `%{fr: "...", ar: "...", en: "..."}` keyed by locale
  atom. Useful for the §7.1 hreflang alternates in the sitemap
  serializer and in the per-record response.
  """
  @spec paths_for_all_locales(map()) :: %{atom() => String.t()}
  def paths_for_all_locales(record) do
    Map.new(@supported_locales, fn locale -> {locale, path_for(record, locale)} end)
  end

  ## Implementation

  # Listings carry their type segment via the property_type's
  # `url_segment` (per-locale). Fall back to the default locale
  # if the requested locale is missing, then to the type's key,
  # then to "listings" as a final default.
  defp listing_type_segment(%{property_type: %Immo.Catalog.PropertyType{} = pt}, locale) do
    type_segment_for(pt, locale)
  end

  defp listing_type_segment(_record, _locale), do: "listings"

  defp type_segment_for(%Immo.Catalog.PropertyType{url_segment: %{} = seg}, locale) do
    seg
    |> Map.get(Atom.to_string(locale), seg[Atom.to_string(@default_locale)])
    |> Kernel.||(seg["fr"] || "listings")
  end

  defp type_segment_for(%Immo.Catalog.PropertyType{key: key}, _locale) do
    # No url_segment at all — fall back to the type key.
    normalize_slug(key)
  end

  defp normalize_slug(nil), do: ""
  defp normalize_slug(""), do: ""

  defp normalize_slug(slug) when is_binary(slug) do
    slug
    |> String.downcase()
    |> String.replace(~r/[\s_]+/u, "-")
    |> String.replace(~r/[^[:alnum:]\-]/u, "")
    |> String.replace(~r/-+/u, "-")
    |> String.trim("-")
  end

  @doc """
  The default locale. Used as the fallback when a record's
  `url_segment` map is missing a key for the requested locale.
  """
  @spec default_locale() :: atom()
  def default_locale, do: @default_locale

  @doc """
  The list of locales the platform ships with (per §1.2 R8).
  New locales require a `url_segment` entry on every property
  type and a translation set for the UI.
  """
  @spec supported_locales() :: [atom()]
  def supported_locales, do: @supported_locales
end
