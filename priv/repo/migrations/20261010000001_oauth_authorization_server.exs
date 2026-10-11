defmodule IdDidiSh.Repo.Migrations.OauthAuthorizationServer do
  use Ecto.Migration

  # The OAuth authorization server for Claude connectors
  # (context-v/plans/OAuth-Authorization-Server-for-Claude-Connectors.md).
  #
  # Same discipline as login_tokens and app tokens: codes, refresh tokens, and
  # client secrets are random values handed out exactly once, and only their
  # SHA-256 hash is stored. Nothing here can be replayed from a database dump.
  def change do
    # Clients register themselves (RFC 7591 dynamic registration). Claude
    # registers a fresh public client per connection, so this table grows with
    # connections, not with apps.
    create table(:oauth_clients, primary_key: false) do
      add :client_id, :string, primary_key: true
      add :client_name, :string, null: false
      add :redirect_uris, {:array, :string}, null: false
      add :token_endpoint_auth_method, :string, null: false
      # Null for public clients (token_endpoint_auth_method "none").
      add :client_secret_hash, :binary
      timestamps(type: :utc_datetime)
    end

    create table(:oauth_authorization_codes) do
      add :code_hash, :binary, null: false

      add :client_id,
          references(:oauth_clients, column: :client_id, type: :string, on_delete: :delete_all),
          null: false

      add :didi_id, references(:users, column: :didi_id, type: :string, on_delete: :delete_all),
        null: false

      # The didi.sh session that consented. Revoking it revokes what it granted.
      add :session_id, references(:sessions, type: :string, on_delete: :delete_all), null: false
      add :entity_id, :string, null: false
      add :redirect_uri, :string, null: false
      add :code_challenge, :string, null: false
      # The registered resource (the token audience), not the raw request value.
      add :resource, :string, null: false
      add :scope, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime
      # Set when the code is exchanged, so a replayed code can revoke the
      # refresh-token family it produced.
      add :family_id, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:oauth_authorization_codes, [:code_hash])

    create table(:oauth_refresh_tokens) do
      add :token_hash, :binary, null: false
      # Every rotation of one grant shares a family. Reuse of a rotated-out
      # token revokes the whole family.
      add :family_id, :string, null: false

      add :client_id,
          references(:oauth_clients, column: :client_id, type: :string, on_delete: :delete_all),
          null: false

      add :didi_id, references(:users, column: :didi_id, type: :string, on_delete: :delete_all),
        null: false

      add :session_id, references(:sessions, type: :string, on_delete: :delete_all), null: false
      add :entity_id, :string, null: false
      add :resource, :string, null: false
      add :scope, :string, null: false
      add :expires_at, :utc_datetime, null: false
      # Set when this token is rotated out (spent).
      add :used_at, :utc_datetime
      add :revoked_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:oauth_refresh_tokens, [:token_hash])
    create index(:oauth_refresh_tokens, [:family_id])
    create index(:oauth_refresh_tokens, [:session_id])
  end
end
