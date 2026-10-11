defmodule IdDidiSh.OAuth.Client do
  use Ecto.Schema

  @primary_key {:client_id, :string, autogenerate: false}
  schema "oauth_clients" do
    field :client_name, :string
    field :redirect_uris, {:array, :string}
    field :token_endpoint_auth_method, :string
    # Hash only — the raw secret is returned once at registration.
    field :client_secret_hash, :binary
    timestamps(type: :utc_datetime)
  end
end
