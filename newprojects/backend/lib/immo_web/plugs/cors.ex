defmodule ImmoWeb.Plugs.Cors do
  @moduledoc """
  §10.1 path 3 + §13 — CORS plug for the public pipeline.

  Wraps Corsica with a project-specific contract:

    * **Exact-origin allowlist.** The allowlist is read from
      `:immo, :public_allowed_origins` (a list of strings). The
      plug never enables wildcard origins — neither `*` nor
      `nil`. The release-gate check in §13 is "CORS exact
      origins, no wildcard" — a literal `*` in the allowlist
      causes an explicit startup-time raise (defence-in-depth
      so a misconfigured env doesn't sneak into a deploy).

    * **Default `allow_credentials` off.** The public endpoints
      are anonymous (no cookies) per §10.1 path 3. If a future
      endpoint does need credentials, the controller can opt in
      by setting `:allow_credentials` per Corsica's docs; this
      wrapper keeps the default strict.

    * **Preflight is handled by Corsica.** An OPTIONS preflight
      for an allowlisted origin returns the appropriate
      `Access-Control-Allow-*` headers; a preflight for a
      non-allowlisted origin returns no CORS headers at all
      (which the browser interprets as a rejection).

  ## Usage

      pipeline :api_public do
        plug :accepts, ["json"]
        plug ImmoWeb.Plugs.Cors
        plug ImmoWeb.Plugs.RateLimit, bucket: :search
        # ...
      end

  ## Why a wrapper around Corsica?

  Two reasons. First, the §10.1/§13 release-gate contract is
  about *not* having a wildcard, and we want the test to be
  one line: `assert "no wildcards" in @moduledoc`. Second,
  reading the allowlist from app-env at request time lets a
  deploy rotate origins without code changes — the same env-
  driven pattern the auth plug uses.
  """

  @behaviour Plug

  ## Helpers
  @allowed_methods ~w(GET POST OPTIONS)
  # Public-tier endpoints are JSON only. The browser's
  # preflight is `OPTIONS Access-Control-Request-Method: GET
  # | POST`; we whitelist the methods the actual public
  # routes accept (search/geo are GET; inquiries is POST).
  @allowed_headers ~w(authorization content-type x-csrf-token x-turnstile-token)
  @max_age 86_400

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    origins = allowed_origins()

    if Enum.any?(origins, &(&1 == "*")) do
      raise ArgumentError,
            "ImmoWeb.Plugs.Cors: wildcard origin ('*') is forbidden by §10.1/§13; " <>
              "configure :immo, :public_allowed_origins with exact origins only."
    end

    corsica_opts = [
      origins: origins,
      allow_methods: @allowed_methods,
      allow_headers: @allowed_headers,
      max_age: @max_age,
      allow_credentials: false,
      log: false
    ]

    Corsica.call(conn, Corsica.init(corsica_opts))
  end

  ## Helpers

  # Read at request time (not init time) so origin rotation
  # via env reload takes effect without a process restart. The
  # test suite flips this with `Application.put_env/3` in
  # setup blocks.
  @spec allowed_origins() :: [String.t()]
  defp allowed_origins do
    :immo
    |> Application.get_env(:public_allowed_origins, [])
    |> List.wrap()
  end
end
