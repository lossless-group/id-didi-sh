defmodule IdDidiSh.Accounts do
  @moduledoc """
  The accounts context: users, login tokens (magic links + invites),
  sessions, and auth events.

  Token discipline (mirrors phx.gen.auth / the calmstorm inventory):
  the raw token is random bytes handed to the user exactly once; only its
  SHA-256 hash is stored. Redemption is single-use (`claimed_at`) and
  TTL-bounded. A magic link only ever authenticates an EXISTING user —
  account creation is invite redemption only (not in the walking skeleton).
  """

  import Ecto.Query

  alias IdDidiSh.Repo
  alias IdDidiSh.UUID7
  alias IdDidiSh.Accounts.{User, Membership, LoginToken, Session, UserEmail}

  @rand_bytes 32

  ## Users

  def get_user(didi_id), do: Repo.get(User, didi_id)

  @doc "Resolve a user by primary email OR any alias — one didi_id, many addresses."
  def get_user_by_email(email) when is_binary(email) do
    lower = String.downcase(email)

    Repo.one(from u in User, where: fragment("lower(?)", u.primary_email) == ^lower) ||
      Repo.one(
        from u in User,
          join: e in UserEmail,
          on: e.didi_id == u.didi_id,
          where: fragment("lower(?)", e.email) == ^lower
      )
  end

  @doc """
  Attach an alt email to a user. Rejected when the address is already any
  user's primary or alias (identity addresses are globally unique).
  """
  def add_email_alias(%User{} = user, email) when is_binary(email) do
    lower = String.downcase(String.trim(email))

    cond do
      not Regex.match?(~r/^[^@\s]+@[^@\s]+$/, lower) ->
        {:error, :invalid_email}

      get_user_by_email(lower) != nil ->
        {:error, :taken}

      true ->
        {:ok, _} = Repo.insert(%UserEmail{didi_id: user.didi_id, email: lower})
        {:ok, lower}
    end
  end

  def list_email_aliases(didi_id) do
    Repo.all(from e in UserEmail, where: e.didi_id == ^didi_id, select: e.email)
  end

  def create_user(attrs) do
    %User{}
    |> User.changeset(Map.put_new(attrs, :didi_id, UUID7.generate()))
    |> Repo.insert()
  end

  def memberships_for(didi_id) do
    Repo.all(from m in Membership, where: m.didi_id == ^didi_id)
  end

  ## Magic links

  @doc """
  Issue a magic-link token for an email. Invite-only posture: if no user
  exists for the email, returns `{:ok, :noop}` — callers respond 202 either
  way so the endpoint doesn't enumerate accounts.

  Returns `{:ok, raw_token, login_token}` when issued.
  """
  def issue_magic_link(email, opts \\ []) do
    case get_user_by_email(email) do
      nil ->
        {:ok, :noop}

      %User{} = user ->
        raw = :crypto.strong_rand_bytes(@rand_bytes) |> Base.url_encode64(padding: false)
        ttl_min = config(:magic_link_ttl_minutes, 15)

        token = %LoginToken{
          kind: "magic_link",
          token_hash: hash(raw),
          email: user.primary_email,
          didi_id: user.didi_id,
          app_slug: Keyword.get(opts, :app_slug),
          next_path: Keyword.get(opts, :next_path),
          expires_at: DateTime.add(now(), ttl_min * 60) |> DateTime.truncate(:second)
        }

        {:ok, token} = Repo.insert(token)
        {:ok, raw, token}
    end
  end

  @doc """
  Redeem a magic-link token: single-use + TTL enforced atomically (the
  UPDATE claims the row only if unclaimed and unexpired). Returns
  `{:ok, user, login_token}` or `{:error, :invalid_token}`.
  """
  def redeem_magic_link(raw) when is_binary(raw) do
    token_hash = hash(raw)
    now = DateTime.truncate(now(), :second)

    claim =
      from t in LoginToken,
        where:
          t.token_hash == ^token_hash and t.kind == "magic_link" and
            is_nil(t.claimed_at) and t.expires_at > ^now

    case Repo.update_all(claim, set: [claimed_at: now]) do
      {1, _} ->
        token = Repo.one!(from t in LoginToken, where: t.token_hash == ^token_hash)
        user = get_user(token.didi_id)
        {:ok, user, token}

      _ ->
        {:error, :invalid_token}
    end
  end

  def redeem_magic_link(_), do: {:error, :invalid_token}

  ## Sessions

  @doc "Create a session row for a user. Returns the session."
  def create_session(%User{} = user, attrs \\ %{}) do
    ttl_days = config(:session_ttl_days, 30)
    now = DateTime.truncate(now(), :second)

    Repo.insert!(%Session{
      id: UUID7.generate(),
      didi_id: user.didi_id,
      expires_at: DateTime.add(now, ttl_days * 24 * 60 * 60),
      last_seen_at: now,
      user_agent: attrs[:user_agent],
      ip: attrs[:ip]
    })
  end

  @doc "A session is alive if it exists, is unrevoked, and is unexpired."
  def get_live_session(session_id) when is_binary(session_id) do
    now = DateTime.truncate(now(), :second)

    Repo.one(
      from s in Session,
        where: s.id == ^session_id and is_nil(s.revoked_at) and s.expires_at > ^now
    )
  end

  def get_live_session(_), do: nil

  @doc "Rolling refresh: bump last_seen_at + extend expires_at."
  def touch_session(%Session{} = session) do
    ttl_days = config(:session_ttl_days, 30)
    now = DateTime.truncate(now(), :second)

    session
    |> Ecto.Changeset.change(
      last_seen_at: now,
      expires_at: DateTime.add(now, ttl_days * 24 * 60 * 60)
    )
    |> Repo.update!()
  end

  def revoke_session(session_id) when is_binary(session_id) do
    now = DateTime.truncate(now(), :second)

    Repo.update_all(
      from(s in Session, where: s.id == ^session_id and is_nil(s.revoked_at)),
      set: [revoked_at: now]
    )

    :ok
  end

  def revoke_session(_), do: :ok

  ## Auth events

  def record_event(event_type, attrs \\ %{}) do
    # Schemaless insert_all — encode the payload map explicitly (SQLite
    # stores JSON as TEXT and the schemaless path has no :map type info).
    payload = if attrs[:payload], do: Jason.encode!(attrs[:payload])

    Repo.insert_all("auth_events", [
      %{
        occurred_at: DateTime.truncate(now(), :second),
        didi_id: attrs[:didi_id],
        app_slug: attrs[:app_slug],
        org_id: attrs[:org_id],
        event_type: event_type,
        payload: payload
      }
    ])

    :ok
  end

  ## Helpers

  defp hash(raw), do: :crypto.hash(:sha256, raw)
  defp now, do: DateTime.utc_now()

  defp config(key, default) do
    Application.get_env(:id_didi_sh, :identity, []) |> Keyword.get(key, default)
  end
end
