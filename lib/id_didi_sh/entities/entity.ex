defmodule IdDidiSh.Entities.Entity do
  use Ecto.Schema

  # kind is a DISPLAY LABEL. It confers no structure and no powers — an
  # "organization" entity is not a parent of a "project" entity, because there
  # are no parents. See Ruling 1.
  @kinds ~w(organization workspace project)

  @primary_key {:id, :string, autogenerate: false}
  schema "entities" do
    field :kind, :string
    field :slug, :string
    field :name, :string
    field :org_id, :string
    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
end
