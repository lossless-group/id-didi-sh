defmodule IdDidiSh.Accounts.Workspace do
  @moduledoc """
  The tenancy boundary, and the boundary secrets attach to.

  `default_domain` is a **self-signup hint**, not an identity. It means "an
  address at this domain may join without an invite". It is never consulted to
  decide whether an existing member has access: auto-join writes an ordinary
  membership row, and from that moment the row is the authority.

  That asymmetry is the point. Clearing or changing a domain cannot revoke
  anyone, so the field is safe to edit — and an advisor at another company is
  expressible, which a domain-derived model cannot manage.
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "workspaces" do
    field :slug, :string
    field :name, :string
    field :org_id, :string
    field :default_domain, :string
    field :default_role, :string, default: "viewer"
    timestamps(type: :utc_datetime)
  end
end
