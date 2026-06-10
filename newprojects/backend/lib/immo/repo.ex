defmodule Immo.Repo do
  use Ecto.Repo,
    otp_app: :immo,
    adapter: Ecto.Adapters.Postgres
end
