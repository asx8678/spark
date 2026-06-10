defmodule Immo.Edge.Paths do
  @moduledoc """
  Single-path authority for the static-site build (P1-E2.5 skeleton).

  Per §6.1, the `Immo.Edge` context owns "path computation" — the
  single source of truth for how a developer/project/listing renders
  to a URL. P1-E5.2 fleshes this out as a `Immo.Edge.Paths.path_for/1`
  function with the §3.9 routing rules (`/{url_segment}/{city}/{slug}`,
  plus a developer fallback for the home page and the §3.8
  slug-rewrite path for redirects).

  P1-E2.5 declares the module + a placeholder function so:
    * P1-E3 (the admin UI) can refer to `Immo.Edge.Paths.path_for/1`
      in templates without runtime crashes;
    * P1-E5.2 lands the real implementation by replacing the body
      of the existing function (callers don't need to change).
  """

  @doc """
  Compute the public URL path for a developer / project / listing.

  P1-E2.5 placeholder: returns "/{slug}" for everything. P1-E5.2
  replaces this with the full §3.9 routing rules (locale prefix,
  property-type segment, city filter, fallback home page).
  """
  @spec path_for(map()) :: String.t()
  def path_for(%{slug: slug}) when is_binary(slug), do: "/" <> slug
  def path_for(_), do: "/"
end
