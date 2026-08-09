defmodule IdDidiSh.Accounts.WorkspaceMembership do
  @moduledoc """
  An explicit grant of a role in a workspace, to a person, by whatever address
  they hold.

  `via` records how the grant happened — `invite`, `auto_join`, or `seed`. It
  exists because "how did this person get access?" is the question that actually
  gets asked, a year later, when an advisor still has it and nobody remembers.
  """

  use Ecto.Schema

  @roles ~w(superuser org_owner org_admin editor viewer)
  @vias ~w(invite auto_join seed)

  schema "workspace_memberships" do
    field :didi_id, :string
    field :workspace_id, :string
    field :role, :string
    field :via, :string, default: "invite"
    field :granted_by, :string
    timestamps(type: :utc_datetime)
  end

  def roles, do: @roles
  def vias, do: @vias
end
