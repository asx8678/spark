defmodule Immo.CRM.Inquiry do
  @moduledoc """
  `inquiries` (§5.7) — leads.

  Per §5.7:
    * `listing_id` fk nullable, `project_id` fk nullable (one of the
      two is expected for a real inquiry; the §5.7 spec keeps both
      nullable so a future "general contact" inquiry has a shape).
    * `name`, `email`, `phone`, `message`.
    * `locale` (the visitor's locale, used for the auto-reply).
    * `consent` boolean (GDPR / Law 09-08).
    * `source` (utm / referrer — debugging, attribution).
    * `status` enum: `new | contacted | closed`.
    * `handled_by_user_id` fk → users nullable (the assigned staff
      member; set when the inquiry moves from `new` to `contacted`).

  Retention: a job (Oban, P1-E6) purges closed inquiries after
  `INQUIRY_RETENTION_DAYS` (default 365). The index on
  `(status, updated_at desc)` is the retention query's path.

  The `Immo.CRM` context (P1-E2.5) owns the workflow (status
  transitions, CSV export, retention). P1-E6 wires the public
  inquiry submission form and the email acknowledgement.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "inquiries" do
    belongs_to :listing, Immo.Catalog.Listing
    belongs_to :project, Immo.Catalog.Project
    belongs_to :handled_by_user, Immo.Accounts.User, foreign_key: :handled_by_user_id

    field :name, :string
    field :email, :string
    field :phone, :string
    field :message, :string
    field :locale, :string
    field :consent, :boolean, default: false
    field :source, :string

    field :status, :string, default: "new"

    timestamps(type: :utc_datetime)
  end
end
