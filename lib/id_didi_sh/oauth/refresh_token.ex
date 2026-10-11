defmodule IdDidiSh.OAuth.RefreshToken do
  use Ecto.Schema

  schema "oauth_refresh_tokens" do
    field :token_hash, :binary
    field :family_id, :string
    field :client_id, :string
    field :didi_id, :string
    field :session_id, :string
    field :entity_id, :string
    field :resource, :string
    field :scope, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime
    field :revoked_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end
end
