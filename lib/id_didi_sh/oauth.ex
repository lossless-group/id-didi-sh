defmodule IdDidiSh.OAuth do
  @moduledoc """
  The OAuth 2.1 authorization server Claude connectors sign in through.

  Plan: `context-v/plans/OAuth-Authorization-Server-for-Claude-Connectors.md`.
  Claude's requirements: https://claude.com/docs/connectors/building/authentication

  What it issues, and to whom:

  - **Clients** register themselves (RFC 7591). Claude supports both Dynamic
    Client Registration and Client ID Metadata Documents, and uses CIMD only
    when the metadata advertises it; otherwise it falls back to DCR. This
    server implements DCR and does not advertise CIMD (see the changelog for
    why). Redirect URIs are an allowlist: Claude's hosted callback, and
    loopback (`localhost` / `127.0.0.1`, any port) for Claude Code.
  - **Authorization codes**: authorization code + PKCE, S256 only, single-use,
    short-lived. Bound to the client, redirect URI, challenge, resource,
    person, consenting session, and chosen entity.
  - **Access tokens**: EdDSA JWTs signed with the same key as `didi_session`
    (`IdDidiSh.Keys`), verifiable against `/.well-known/jwks.json`.
    `typ: at+jwt` (RFC 9068), `aud` = the registered resource, `sub` = didi_id,
    `entity` = `%{"id", "slug"}`. No `sid` claim, so an access token can never
    pass as a session cookie (`IdDidiSh.Token.verify/1` requires `sid`).
  - **Refresh tokens**: rotated on every use. Presenting a rotated-out token
    revokes its whole family. Each family is tied to the didi.sh session that
    consented, so signing out (revoking that session) kills its refresh tokens.

  Codes, refresh tokens, and client secrets are stored only as SHA-256 hashes.

  Every URL this server advertises is built from the configured `issuer`,
  never from the request: Fly's proxy forwards plain http, and an `http://`
  endpoint in discovery breaks Claude.
  """

  import Ecto.Query

  alias IdDidiSh.{Accounts, Entities, Keys, Repo, UUID7}
  alias IdDidiSh.OAuth.{AuthorizationCode, Client, RefreshToken}

  @claude_callback "https://claude.ai/api/mcp/auth_callback"
  @scopes_supported ["profile", "offline_access"]
  @auth_methods ["none", "client_secret_basic", "client_secret_post"]
  @rand_bytes 32

  ## Configuration

  def issuer, do: config(:issuer, "https://id.didi.sh")

  def access_token_ttl, do: config(:oauth_access_token_ttl_seconds, 3600)
  def refresh_token_ttl_days, do: config(:oauth_refresh_token_ttl_days, 30)
  def code_ttl, do: config(:oauth_code_ttl_seconds, 120)

  @doc "Registered resources (token audiences): `[%{uri: _, name: _}]`."
  def resources, do: config(:oauth_resources, [])

  defp allowed_https_redirects, do: config(:oauth_redirect_uris, [@claude_callback])

  ## Discovery

  @doc "RFC 8414 authorization server metadata."
  def metadata do
    iss = issuer()

    %{
      "issuer" => iss,
      "authorization_endpoint" => iss <> "/oauth/authorize",
      "token_endpoint" => iss <> "/oauth/token",
      "registration_endpoint" => iss <> "/oauth/register",
      "jwks_uri" => iss <> "/.well-known/jwks.json",
      "scopes_supported" => @scopes_supported,
      "response_types_supported" => ["code"],
      "response_modes_supported" => ["query"],
      "grant_types_supported" => ["authorization_code", "refresh_token"],
      "token_endpoint_auth_methods_supported" => @auth_methods,
      "code_challenge_methods_supported" => ["S256"],
      "authorization_response_iss_parameter_supported" => true
    }
  end

  @doc """
  OpenID Connect Discovery 1.0 document: the same server, plus the fields the
  OIDC spec requires. No `id_token` is issued yet (see the changelog).
  """
  def openid_configuration do
    Map.merge(metadata(), %{
      "subject_types_supported" => ["public"],
      "id_token_signing_alg_values_supported" => ["EdDSA"]
    })
  end

  ## Redirect URIs

  @doc """
  May a client register this redirect URI at all? Claude's hosted callback
  (exact match), or an `http` loopback on `localhost` / `127.0.0.1`.
  """
  def allowed_redirect_uri?(uri) when is_binary(uri) do
    uri in allowed_https_redirects() or loopback?(uri)
  end

  def allowed_redirect_uri?(_), do: false

  @doc """
  Does the requested redirect URI match one the client registered? Exact
  match, except loopback, where the port is ignored (RFC 8252 §7.3): Claude
  Code binds an ephemeral port per session.
  """
  def redirect_registered?(%Client{redirect_uris: registered}, requested)
      when is_binary(requested) do
    requested in registered or
      (loopback?(requested) and Enum.any?(registered, &same_loopback?(&1, requested)))
  end

  def redirect_registered?(_, _), do: false

  def loopback?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: "http", host: host, userinfo: nil, fragment: nil, path: "/" <> _}
      when host in ["localhost", "127.0.0.1"] ->
        true

      _ ->
        false
    end
  end

  def loopback?(_), do: false

  defp same_loopback?(registered, requested) do
    reg = URI.parse(registered)
    req = URI.parse(requested)

    loopback?(registered) and reg.host == req.host and reg.path == req.path and
      reg.query == req.query
  end

  ## Resources

  @doc """
  Resolve a `resource` parameter (RFC 8707) to a registered resource.

  A request matches a registered resource when it has the same https origin
  and its path is the registered path or beneath it. Claude sends the MCP
  server URL as the person typed it (`https://memopop.didi.sh/mcp`); the
  audience is still the registered resource (`https://memopop.didi.sh`), which
  is what MemoPop verifies. Fragments, queries, other ports, and look-alike
  hosts never match.
  """
  def resolve_resource(nil), do: {:error, :missing}
  def resolve_resource(""), do: {:error, :missing}

  def resolve_resource(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil} = req
      when is_binary(host) ->
        Enum.find_value(resources(), {:error, :invalid_target}, fn r ->
          reg = URI.parse(r.uri)

          if reg.host == req.host and reg.port == req.port and
               path_under?(req.path, reg.path) do
            {:ok, r}
          end
        end)

      _ ->
        {:error, :invalid_target}
    end
  end

  def resolve_resource(_), do: {:error, :invalid_target}

  defp path_under?(req_path, reg_path) do
    reg = String.trim_trailing(reg_path || "", "/")
    req = req_path || ""
    reg == "" or req == reg or String.starts_with?(req, reg <> "/")
  end

  ## Clients (RFC 7591)

  @doc """
  Register a client from its metadata. Returns `{:ok, response_map}` (the RFC
  7591 response, including `client_secret` once for confidential clients) or
  `{:error, error_code, description}`.
  """
  def register_client(params) when is_map(params) do
    redirect_uris = params["redirect_uris"]
    method = params["token_endpoint_auth_method"] || "client_secret_basic"

    cond do
      not (is_list(redirect_uris) and redirect_uris != []) ->
        {:error, "invalid_redirect_uri", "redirect_uris is required"}

      not Enum.all?(redirect_uris, &allowed_redirect_uri?/1) ->
        {:error, "invalid_redirect_uri",
         "redirect_uris must be #{@claude_callback} or an http loopback (localhost or 127.0.0.1)"}

      method not in @auth_methods ->
        {:error, "invalid_client_metadata",
         "token_endpoint_auth_method must be one of #{Enum.join(@auth_methods, ", ")}"}

      not subset?(params["grant_types"], ["authorization_code", "refresh_token"]) ->
        {:error, "invalid_client_metadata",
         "grant_types may only include authorization_code and refresh_token"}

      not subset?(params["response_types"], ["code"]) ->
        {:error, "invalid_client_metadata", "response_types may only include code"}

      true ->
        insert_client(params, redirect_uris, method)
    end
  end

  def register_client(_), do: {:error, "invalid_client_metadata", "expected a JSON object"}

  defp subset?(nil, _allowed), do: true
  defp subset?(list, allowed) when is_list(list), do: Enum.all?(list, &(&1 in allowed))
  defp subset?(_, _), do: false

  defp insert_client(params, redirect_uris, method) do
    now = now()
    client_id = "dcr_" <> random()
    secret = if method == "none", do: nil, else: random()

    name =
      case params["client_name"] do
        n when is_binary(n) and n != "" -> n |> String.trim() |> String.slice(0, 100)
        _ -> "Unnamed app"
      end

    {:ok, client} =
      Repo.insert(%Client{
        client_id: client_id,
        client_name: name,
        redirect_uris: redirect_uris,
        token_endpoint_auth_method: method,
        client_secret_hash: secret && hash(secret),
        inserted_at: now,
        updated_at: now
      })

    Accounts.record_event("oauth_client_registered", %{
      payload: %{"client_id" => client_id, "client_name" => name, "method" => method}
    })

    response =
      %{
        "client_id" => client.client_id,
        "client_id_issued_at" => DateTime.to_unix(now),
        "client_name" => client.client_name,
        "redirect_uris" => client.redirect_uris,
        "grant_types" => ["authorization_code", "refresh_token"],
        "response_types" => ["code"],
        "token_endpoint_auth_method" => method
      }
      |> then(fn r ->
        if secret,
          do: Map.merge(r, %{"client_secret" => secret, "client_secret_expires_at" => 0}),
          else: r
      end)

    {:ok, response}
  end

  def get_client(client_id) when is_binary(client_id), do: Repo.get(Client, client_id)
  def get_client(_), do: nil

  @doc """
  Authenticate a client at the token endpoint. `client_id` / `client_secret`
  come from HTTP Basic or the form body (the controller extracts them).
  Public clients authenticate by `client_id` alone; PKCE is their proof.
  """
  def authenticate_client(client_id, secret) do
    case get_client(client_id) do
      nil ->
        {:error, "invalid_client", "unknown client"}

      %Client{token_endpoint_auth_method: "none"} = client ->
        {:ok, client}

      %Client{client_secret_hash: stored} = client when is_binary(secret) ->
        if Plug.Crypto.secure_compare(hash(secret), stored),
          do: {:ok, client},
          else: {:error, "invalid_client", "client authentication failed"}

      _ ->
        {:error, "invalid_client", "client authentication failed"}
    end
  end

  ## The authorization request

  @authorize_fields ~w(response_type client_id redirect_uri code_challenge code_challenge_method state scope resource)

  @doc "The authorization-request parameters, and only those."
  def authorize_fields, do: @authorize_fields

  @doc """
  Validate an authorization request (RFC 6749 §4.1.1 + PKCE + RFC 8707).

  - `{:error_page, message}`: the client or redirect URI cannot be trusted,
    so the error is shown here and never redirected (RFC 6749 §4.1.2.1).
  - `{:redirect_error, redirect_uri, state, error, description}`: anything
    else, reported back to the client.
  - `{:ok, request}` with the client, redirect URI, challenge, resolved
    resource, granted scope, and state.
  """
  def validate_authorization_request(params) do
    client = get_client(params["client_id"])
    redirect_uri = params["redirect_uri"]
    state = params["state"]

    cond do
      is_nil(client) ->
        {:error_page, "This app is not registered with didi.sh."}

      not redirect_registered?(client, redirect_uri) ->
        {:error_page, "This app asked to be sent somewhere it never registered."}

      params["response_type"] in [nil, ""] ->
        {:redirect_error, redirect_uri, state, "invalid_request", "response_type is required"}

      params["response_type"] != "code" ->
        {:redirect_error, redirect_uri, state, "unsupported_response_type",
         "only response_type=code is supported"}

      params["code_challenge"] in [nil, ""] ->
        {:redirect_error, redirect_uri, state, "invalid_request",
         "a PKCE code_challenge is required"}

      params["code_challenge_method"] != "S256" ->
        {:redirect_error, redirect_uri, state, "invalid_request",
         "code_challenge_method must be S256"}

      not Regex.match?(~r/^[A-Za-z0-9_-]{43}$/, params["code_challenge"]) ->
        {:redirect_error, redirect_uri, state, "invalid_request",
         "code_challenge must be a base64url SHA-256 digest"}

      true ->
        case resolve_resource(params["resource"]) do
          {:error, :missing} ->
            {:redirect_error, redirect_uri, state, "invalid_request",
             "the resource parameter is required"}

          {:error, :invalid_target} ->
            {:redirect_error, redirect_uri, state, "invalid_target",
             "resource is not registered with didi.sh"}

          {:ok, resource} ->
            {:ok,
             %{
               client: client,
               redirect_uri: redirect_uri,
               state: state,
               code_challenge: params["code_challenge"],
               resource: resource,
               scope: grant_scope(params["scope"])
             }}
        end
    end
  end

  # Unknown scopes are dropped, not refused (RFC 6749 §3.3 lets the server
  # grant less than asked); the token response states what was granted.
  defp grant_scope(requested) do
    asked = String.split(requested || "", " ", trim: true)
    granted = Enum.filter(@scopes_supported, &(&1 in asked))
    Enum.join(Enum.uniq(["profile" | granted]), " ")
  end

  @doc "Entities a person may pick on the consent screen."
  def entity_choices(didi_id), do: Entities.list_entities_for(didi_id)

  @doc """
  Issue a code for an approved request. The entity must be one the person
  can reach. Returns `{:ok, raw_code}` or `{:error, :entity_not_allowed}`.
  """
  def issue_code(request, user, session, entity_id) do
    if entity_reachable?(user.didi_id, entity_id) do
      raw = random()
      now = now()

      Repo.insert!(%AuthorizationCode{
        code_hash: hash(raw),
        client_id: request.client.client_id,
        didi_id: user.didi_id,
        session_id: session.id,
        entity_id: entity_id,
        redirect_uri: request.redirect_uri,
        code_challenge: request.code_challenge,
        resource: request.resource.uri,
        scope: request.scope,
        expires_at: DateTime.add(now, code_ttl())
      })

      Accounts.record_event("oauth_consent_granted", %{
        didi_id: user.didi_id,
        payload: %{
          "client_id" => request.client.client_id,
          "entity_id" => entity_id,
          "resource" => request.resource.uri
        }
      })

      {:ok, raw}
    else
      {:error, :entity_not_allowed}
    end
  end

  defp entity_reachable?(didi_id, entity_id) when is_binary(entity_id) do
    Enum.any?(entity_choices(didi_id), &(&1.id == entity_id))
  end

  defp entity_reachable?(_, _), do: false

  ## Token endpoint

  @doc """
  `grant_type=authorization_code`. Everything is checked before the code is
  claimed, so a malformed attempt (wrong resource, say) does not burn it; the
  claim itself is an atomic UPDATE, so two exchanges cannot both win.
  """
  def exchange_code(%Client{} = client, params) do
    now = now()

    code =
      if is_binary(params["code"]),
        do: Repo.get_by(AuthorizationCode, code_hash: hash(params["code"]))

    cond do
      params["code"] in [nil, ""] ->
        {:error, "invalid_request", "code is required"}

      is_nil(code) ->
        {:error, "invalid_grant", "unknown authorization code"}

      not is_nil(code.used_at) ->
        # A replayed code: whatever it produced is suspect.
        if code.family_id, do: revoke_family(code.family_id)
        {:error, "invalid_grant", "authorization code already used"}

      DateTime.compare(code.expires_at, now) != :gt ->
        {:error, "invalid_grant", "authorization code expired"}

      code.client_id != client.client_id ->
        {:error, "invalid_grant", "code was issued to another client"}

      params["redirect_uri"] != code.redirect_uri ->
        {:error, "invalid_grant", "redirect_uri does not match the authorization request"}

      not pkce_ok?(params["code_verifier"], code.code_challenge) ->
        {:error, "invalid_grant", "PKCE verification failed"}

      not same_resource?(params["resource"], code.resource) ->
        {:error, "invalid_target", "resource does not match the authorization request"}

      is_nil(Accounts.get_live_session(code.session_id)) ->
        {:error, "invalid_grant", "the didi.sh session that consented has ended"}

      true ->
        family_id = UUID7.generate()

        claim =
          from c in AuthorizationCode,
            where: c.id == ^code.id and is_nil(c.used_at)

        case Repo.update_all(claim, set: [used_at: now, family_id: family_id]) do
          {1, _} ->
            issue_tokens(%{
              family_id: family_id,
              client_id: client.client_id,
              didi_id: code.didi_id,
              session_id: code.session_id,
              entity_id: code.entity_id,
              resource: code.resource,
              scope: code.scope
            })

          _ ->
            {:error, "invalid_grant", "authorization code already used"}
        end
    end
  end

  @doc """
  `grant_type=refresh_token`. Rotates: the presented token is spent and a new
  one returned in the same response. A spent token presented again revokes
  the family (OAuth 2.1 §4.3.1 / MCP 2025-11-25 "token theft").
  """
  def refresh(%Client{} = client, params) do
    now = now()
    raw = params["refresh_token"]
    token = if is_binary(raw), do: Repo.get_by(RefreshToken, token_hash: hash(raw))
    session = token && Accounts.get_live_session(token.session_id)

    cond do
      raw in [nil, ""] ->
        {:error, "invalid_request", "refresh_token is required"}

      is_nil(token) ->
        {:error, "invalid_grant", "unknown refresh token"}

      token.client_id != client.client_id ->
        {:error, "invalid_grant", "refresh token was issued to another client"}

      not is_nil(token.revoked_at) ->
        {:error, "invalid_grant", "refresh token revoked"}

      not is_nil(token.used_at) ->
        revoke_family(token.family_id)

        Accounts.record_event("oauth_refresh_reuse", %{
          didi_id: token.didi_id,
          payload: %{"client_id" => token.client_id, "family_id" => token.family_id}
        })

        {:error, "invalid_grant", "refresh token already used; the grant is revoked"}

      DateTime.compare(token.expires_at, now) != :gt ->
        {:error, "invalid_grant", "refresh token expired"}

      not same_resource?(params["resource"], token.resource) ->
        {:error, "invalid_target", "resource does not match the grant"}

      is_nil(session) ->
        revoke_family(token.family_id)
        {:error, "invalid_grant", "the didi.sh session behind this grant has ended"}

      not entity_reachable?(token.didi_id, token.entity_id) ->
        revoke_family(token.family_id)
        {:error, "invalid_grant", "no longer a member of that entity"}

      true ->
        claim =
          from t in RefreshToken,
            where: t.id == ^token.id and is_nil(t.used_at) and is_nil(t.revoked_at)

        case Repo.update_all(claim, set: [used_at: now, updated_at: now]) do
          {1, _} ->
            # A connector in use keeps the session that authorized it alive,
            # the same rolling window a browser gets from /api/session/refresh.
            Accounts.touch_session(session)

            issue_tokens(
              Map.take(
                token,
                ~w(family_id client_id didi_id session_id entity_id resource scope)a
              )
            )

          _ ->
            revoke_family(token.family_id)
            {:error, "invalid_grant", "refresh token already used; the grant is revoked"}
        end
    end
  end

  defp issue_tokens(grant) do
    raw_refresh = random()
    now = now()

    Repo.insert!(%RefreshToken{
      token_hash: hash(raw_refresh),
      family_id: grant.family_id,
      client_id: grant.client_id,
      didi_id: grant.didi_id,
      session_id: grant.session_id,
      entity_id: grant.entity_id,
      resource: grant.resource,
      scope: grant.scope,
      expires_at: DateTime.add(now, refresh_token_ttl_days() * 24 * 60 * 60)
    })

    {:ok,
     %{
       "access_token" => sign_access_token(grant),
       "token_type" => "Bearer",
       "expires_in" => access_token_ttl(),
       "refresh_token" => raw_refresh,
       "scope" => grant.scope
     }}
  end

  @doc """
  Mint an access token. Header `{alg: EdDSA, kid, typ: at+jwt}`; claims
  `iss sub aud exp iat jti client_id scope entity`.
  """
  def sign_access_token(grant) do
    now = System.system_time(:second)
    entity = Entities.get_entity(grant.entity_id)

    claims = %{
      "iss" => issuer(),
      "sub" => grant.didi_id,
      "aud" => grant.resource,
      "iat" => now,
      "exp" => now + access_token_ttl(),
      "jti" => UUID7.generate(),
      "client_id" => grant.client_id,
      "scope" => grant.scope,
      "entity" => %{"id" => grant.entity_id, "slug" => entity && entity.slug}
    }

    {_meta, compact} =
      Keys.signing_jwk()
      |> JOSE.JWT.sign(%{"alg" => "EdDSA", "kid" => Keys.kid(), "typ" => "at+jwt"}, claims)
      |> JOSE.JWS.compact()

    compact
  end

  defp revoke_family(family_id) do
    now = now()

    Repo.update_all(
      from(t in RefreshToken, where: t.family_id == ^family_id and is_nil(t.revoked_at)),
      set: [revoked_at: now, updated_at: now]
    )

    :ok
  end

  # The token request may omit resource (the code already carries it); if it
  # names one, it must resolve to the same registered resource.
  defp same_resource?(nil, _granted), do: true
  defp same_resource?("", _granted), do: true

  defp same_resource?(requested, granted) do
    case resolve_resource(requested) do
      {:ok, %{uri: ^granted}} -> true
      _ -> false
    end
  end

  defp pkce_ok?(verifier, challenge)
       when is_binary(verifier) and byte_size(verifier) >= 43 and byte_size(verifier) <= 128 do
    computed = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    Plug.Crypto.secure_compare(computed, challenge)
  end

  defp pkce_ok?(_, _), do: false

  ## Helpers

  defp random, do: :crypto.strong_rand_bytes(@rand_bytes) |> Base.url_encode64(padding: false)
  defp hash(raw), do: :crypto.hash(:sha256, raw)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp config(key, default) do
    Application.get_env(:id_didi_sh, :identity, []) |> Keyword.get(key, default)
  end
end
