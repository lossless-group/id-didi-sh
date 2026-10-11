defmodule IdDidiSh.OAuth.AuthorizationCode do
  use Ecto.Schema

  schema "oauth_authorization_codes" do
    field :code_hash, :binary
    field :client_id, :string
    field :didi_id, :string
    field :session_id, :string
    field :entity_id, :string
    field :redirect_uri, :string
    field :code_challenge, :string
    field :resource, :string
    field :scope, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime
    field :family_id, :string
    timestamps(type: :utc_datetime)
  end
end
