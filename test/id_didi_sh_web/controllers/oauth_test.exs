defmodule IdDidiShWeb.OAuthTest do
  @moduledoc """
  The OAuth authorization server Claude connectors sign in through.

  Spec IDs OAUTH-01..10 come from
  `context-v/plans/OAuth-Authorization-Server-for-Claude-Connectors.md`.

  `async: false` because OAUTH-01 sets the configured issuer to the production
  value for its duration (the test env issuer is `http://localhost:4002`), and
  ExUnit runs sync modules only after every async module has finished.
  """
  use IdDidiShWeb.ConnCase, async: false

  import Swoosh.TestAssertions

  alias IdDidiSh.{Accounts, Entities, Token}

  @claude_cb "https://claude.ai/api/mcp/auth_callback"
  @memopop "https://memopop.didi.sh"
  @decks "https://decks.didi.sh"

  # ── helpers ───────────────────────────────────────────────────────────────

  defp register(body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> post("/oauth/register", Jason.encode!(body))
  end

  defp client_metadata(redirect_uris) do
    %{
      "client_name" => "Claude",
      "redirect_uris" => redirect_uris,
      "grant_types" => ["authorization_code", "refresh_token"],
      "response_types" => ["code"],
      "token_endpoint_auth_method" => "none"
    }
  end

  defp client!(redirect_uris \\ [@claude_cb]) do
    conn = register(client_metadata(redirect_uris))
    %{"client_id" => client_id} = json_response(conn, 201)
    client_id
  end

  defp signed_in(email) do
    {:ok, user} = Accounts.create_user(%{primary_email: email, name: "Partner"})
    session = Accounts.create_session(user)
    {user, session, Token.sign(user.didi_id, session.id)}
  end

  defp entity!(slug, didi_id) do
    {:ok, entity} =
      Entities.create_entity(%{
        "kind" => "organization",
        "slug" => slug,
        "name" => "Firm #{slug}"
      })

    {:ok, _} = Entities.add_member(entity.id, didi_id, "viewer", via: "seed")
    entity
  end

  defp pkce do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  defp authorize_params(client_id, challenge, overrides \\ %{}) do
    Map.merge(
      %{
        "response_type" => "code",
        "client_id" => client_id,
        "redirect_uri" => @claude_cb,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => "state-123",
        "scope" => "offline_access",
        "resource" => @memopop
      },
      overrides
    )
  end

  defp get_authorize(cookie, params) do
    conn = build_conn()
    conn = if cookie, do: put_req_cookie(conn, "didi_session", cookie), else: conn
    get(conn, "/oauth/authorize?" <> URI.encode_query(params))
  end

  defp approve(cookie, params, entity_id) do
    build_conn()
    |> put_req_cookie("didi_session", cookie)
    |> post(
      "/oauth/authorize",
      Map.merge(params, %{"entity_id" => entity_id, "decision" => "approve"})
    )
  end

  defp redirect_query(conn) do
    location = redirected_to(conn, 302)
    uri = URI.parse(location)
    {uri, URI.decode_query(uri.query || "")}
  end

  defp token(params) do
    build_conn()
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> put_req_header("accept", "application/json")
    |> post("/oauth/token", URI.encode_query(params))
  end

  # The whole browser half: a signed-in person in one firm approves, and the
  # client gets a code back on its callback.
  defp code_flow(opts \\ []) do
    email = Keyword.get(opts, :email, "partner-#{System.unique_integer([:positive])}@firm.test")
    resource = Keyword.get(opts, :resource, @memopop)
    {user, session, cookie} = signed_in(email)
    entity = entity!("firm-#{System.unique_integer([:positive])}", user.didi_id)
    client_id = client!()
    {verifier, challenge} = pkce()
    params = authorize_params(client_id, challenge, %{"resource" => resource})

    conn = approve(cookie, params, entity.id)
    {_uri, query} = redirect_query(conn)

    %{
      user: user,
      session: session,
      cookie: cookie,
      entity: entity,
      client_id: client_id,
      verifier: verifier,
      code: query["code"],
      resource: resource
    }
  end

  defp exchange(flow, overrides \\ %{}) do
    token(
      Map.merge(
        %{
          "grant_type" => "authorization_code",
          "code" => flow.code,
          "redirect_uri" => @claude_cb,
          "client_id" => flow.client_id,
          "code_verifier" => flow.verifier,
          "resource" => flow.resource
        },
        overrides
      )
    )
  end

  defp refresh(client_id, refresh_token, overrides \\ %{}) do
    token(
      Map.merge(
        %{
          "grant_type" => "refresh_token",
          "refresh_token" => refresh_token,
          "client_id" => client_id
        },
        overrides
      )
    )
  end

  # Verify exactly as a resource server does: fetch the published JWKS, pick
  # the key by kid, check the EdDSA signature. Nothing private is used.
  defp verify_against_jwks(access_token) do
    %{"keys" => keys} = build_conn() |> get("/.well-known/jwks.json") |> json_response(200)
    %JOSE.JWS{fields: header} = JOSE.JWT.peek_protected(access_token)
    key = Enum.find(keys, &(&1["kid"] == header["kid"]))
    assert key, "no JWKS key matches the token's kid"

    {verified?, %JOSE.JWT{fields: claims}, _} =
      JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), ["EdDSA"], access_token)

    {verified?, header, claims}
  end

  # ── OAUTH-01 ──────────────────────────────────────────────────────────────

  describe "discovery" do
    setup do
      previous = Application.get_env(:id_didi_sh, :identity)

      Application.put_env(
        :id_didi_sh,
        :identity,
        Keyword.put(previous, :issuer, "https://id.didi.sh")
      )

      on_exit(fn -> Application.put_env(:id_didi_sh, :identity, previous) end)
      :ok
    end

    @tag spec: "OAUTH-01"
    test "both documents list every endpoint over https, even on a plain-http request" do
      for path <- ["/.well-known/oauth-authorization-server", "/.well-known/openid-configuration"] do
        # build_conn/0 is a plain http request to www.example.com — the shape
        # Fly's proxy hands the app. Nothing in the answer may come from it.
        conn = get(build_conn(), path)
        assert conn.scheme == :http
        doc = json_response(conn, 200)

        assert doc["issuer"] == "https://id.didi.sh"
        assert doc["authorization_endpoint"] == "https://id.didi.sh/oauth/authorize"
        assert doc["token_endpoint"] == "https://id.didi.sh/oauth/token"
        assert doc["registration_endpoint"] == "https://id.didi.sh/oauth/register"
        assert doc["jwks_uri"] == "https://id.didi.sh/.well-known/jwks.json"
        assert doc["code_challenge_methods_supported"] == ["S256"]
        assert "authorization_code" in doc["grant_types_supported"]
        assert "refresh_token" in doc["grant_types_supported"]
        assert doc["response_types_supported"] == ["code"]
        assert "none" in doc["token_endpoint_auth_methods_supported"]
        assert "offline_access" in doc["scopes_supported"]

        urls = for {_k, v} <- doc, is_binary(v), String.contains?(v, "://"), do: v
        assert urls != []
        for url <- urls, do: assert(String.starts_with?(url, "https://"), "#{path}: #{url}")
        refute inspect(doc) =~ "example.com"
      end
    end
  end

  # ── OAUTH-02 ──────────────────────────────────────────────────────────────

  describe "dynamic client registration" do
    @tag spec: "OAUTH-02"
    test "accepts Claude's callback and loopback redirects, rejects anything else" do
      conn = register(client_metadata([@claude_cb]))
      body = json_response(conn, 201)
      assert is_binary(body["client_id"]) and byte_size(body["client_id"]) >= 16
      assert body["redirect_uris"] == [@claude_cb]
      assert body["token_endpoint_auth_method"] == "none"
      assert is_integer(body["client_id_issued_at"])

      for loopback <- [
            "http://localhost:3118/callback",
            "http://127.0.0.1:53682/callback",
            "http://localhost/callback"
          ] do
        assert %{"client_id" => _} = json_response(register(client_metadata([loopback])), 201)
      end

      for bad <- [
            "https://evil.example/api/mcp/auth_callback",
            "http://claude.ai/api/mcp/auth_callback",
            "https://claude.ai/api/mcp/other",
            "https://claude.ai.evil.example/api/mcp/auth_callback",
            "http://localhost.evil.example/callback",
            "https://localhost/callback",
            "http://192.168.1.10:8080/callback",
            "javascript:alert(1)",
            "not a uri"
          ] do
        conn = register(client_metadata([bad]))
        assert %{"error" => "invalid_redirect_uri"} = json_response(conn, 400), bad
      end

      # One bad apple spoils the registration: no partial accept.
      conn = register(client_metadata([@claude_cb, "https://evil.example/cb"]))
      assert %{"error" => "invalid_redirect_uri"} = json_response(conn, 400)

      conn = register(Map.delete(client_metadata([@claude_cb]), "redirect_uris"))
      assert %{"error" => "invalid_redirect_uri"} = json_response(conn, 400)
    end
  end

  # ── OAUTH-03 ──────────────────────────────────────────────────────────────

  describe "authorize without a session" do
    @tag spec: "OAUTH-03"
    test "sends the person through magic-link sign-in and back to authorize" do
      {:ok, user} = Accounts.create_user(%{primary_email: "newcomer@firm.test"})
      entity = entity!("newcomer-firm", user.didi_id)
      client_id = client!()
      {_verifier, challenge} = pkce()
      params = authorize_params(client_id, challenge)

      # 1. No cookie: off to the existing sign-in page, carrying the way back.
      conn = get_authorize(nil, params)
      signin = redirected_to(conn, 302)
      assert String.starts_with?(signin, "/auth?")
      return_to = URI.decode_query(URI.parse(signin).query)["return_to"]
      assert String.starts_with?(return_to, "/oauth/authorize?")

      # 2. The sign-in page keeps the way back in the form.
      page = build_conn() |> get(signin) |> html_response(200)
      assert page =~ "return_to"

      # 3. Submitting the email sends the ordinary magic link.
      conn =
        post(build_conn(), "/auth", %{"email" => "newcomer@firm.test", "return_to" => return_to})

      assert html_response(conn, 200) =~ "Check your email"

      raw =
        receive do
          {:email, email} ->
            [_, raw] = Regex.run(~r{/access\?token=([A-Za-z0-9_\-]+)}, email.text_body)
            raw
        after
          1000 -> flunk("no magic-link email was sent")
        end

      # 4. Redeeming the link signs them in and returns them to authorize.
      conn = post(build_conn(), "/access", %{"token" => raw})
      assert redirected_to(conn, 302) == return_to
      cookie = conn.resp_cookies["didi_session"][:value]
      assert is_binary(cookie)

      # 5. Back at authorize with the session: the consent screen.
      conn = build_conn() |> put_req_cookie("didi_session", cookie) |> get(return_to)
      html = html_response(conn, 200)
      assert html =~ "Claude"
      assert html =~ entity.name
      assert html =~ "claude.ai"
    end

    @tag spec: "OAUTH-03"
    test "the sign-in hop never carries a way back that leaves authorize" do
      {:ok, _user} = Accounts.create_user(%{primary_email: "drifter@firm.test"})

      for evil <- ["https://evil.example/", "//evil.example/oauth/authorize", "/account"] do
        post(build_conn(), "/auth", %{"email" => "drifter@firm.test", "return_to" => evil})

        raw =
          receive do
            {:email, email} ->
              [_, raw] = Regex.run(~r{/access\?token=([A-Za-z0-9_\-]+)}, email.text_body)
              raw
          after
            1000 -> flunk("no magic-link email was sent")
          end

        conn = post(build_conn(), "/access", %{"token" => raw})
        # No redirect anywhere: the ordinary "signed in" page.
        assert html_response(conn, 200) =~ "Signed in"
      end
    end
  end

  # ── OAUTH-04 ──────────────────────────────────────────────────────────────

  describe "authorize request validation" do
    setup do
      {user, _session, cookie} = signed_in("validator@firm.test")
      entity = entity!("validator-firm", user.didi_id)
      client_id = client!([@claude_cb, "http://localhost/callback"])
      {_verifier, challenge} = pkce()
      %{cookie: cookie, entity: entity, client_id: client_id, challenge: challenge}
    end

    @tag spec: "OAUTH-04"
    test "a valid request reaches consent, including a loopback redirect on any port", ctx do
      conn = get_authorize(ctx.cookie, authorize_params(ctx.client_id, ctx.challenge))
      assert html_response(conn, 200) =~ ctx.entity.name

      loopback =
        authorize_params(ctx.client_id, ctx.challenge, %{
          "redirect_uri" => "http://localhost:49152/callback"
        })

      assert html_response(get_authorize(ctx.cookie, loopback), 200) =~ ctx.entity.name
    end

    @tag spec: "OAUTH-04"
    test "missing or non-S256 PKCE is refused back to the client with no code", ctx do
      for overrides <- [
            %{"code_challenge" => nil},
            %{"code_challenge_method" => "plain"},
            %{"code_challenge_method" => nil}
          ] do
        params =
          authorize_params(ctx.client_id, ctx.challenge)
          |> Map.merge(overrides)
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()

        for conn <- [
              get_authorize(ctx.cookie, params),
              approve(ctx.cookie, params, ctx.entity.id)
            ] do
          {uri, query} = redirect_query(conn)
          assert URI.to_string(%{uri | query: nil}) == @claude_cb
          assert query["error"] == "invalid_request"
          assert query["state"] == "state-123"
          refute Map.has_key?(query, "code")
        end
      end
    end

    @tag spec: "OAUTH-04"
    test "an unknown client or unregistered redirect gets an error page, never a redirect", ctx do
      unknown = authorize_params("no-such-client", ctx.challenge)

      unregistered =
        authorize_params(ctx.client_id, ctx.challenge, %{
          "redirect_uri" => "https://evil.example/cb"
        })

      loopback_other_path =
        authorize_params(ctx.client_id, ctx.challenge, %{
          "redirect_uri" => "http://localhost:5000/elsewhere"
        })

      for params <- [unknown, unregistered, loopback_other_path] do
        for conn <- [
              get_authorize(ctx.cookie, params),
              approve(ctx.cookie, params, ctx.entity.id)
            ] do
          assert conn.status == 400
          assert get_resp_header(conn, "location") == []
        end
      end
    end

    @tag spec: "OAUTH-04"
    test "an unknown resource is refused with invalid_target, a missing one with invalid_request",
         ctx do
      for resource <- [
            "https://evil.example",
            "https://memopop.didi.sh.evil.example",
            "http://memopop.didi.sh",
            "https://memopop.didi.sh:8443",
            "https://memopop.didi.sh#frag"
          ] do
        params = authorize_params(ctx.client_id, ctx.challenge, %{"resource" => resource})

        for conn <- [
              get_authorize(ctx.cookie, params),
              approve(ctx.cookie, params, ctx.entity.id)
            ] do
          {_uri, query} = redirect_query(conn)
          assert query["error"] == "invalid_target", resource
          refute Map.has_key?(query, "code")
        end
      end

      params = authorize_params(ctx.client_id, ctx.challenge) |> Map.delete("resource")

      for conn <- [get_authorize(ctx.cookie, params), approve(ctx.cookie, params, ctx.entity.id)] do
        {_uri, query} = redirect_query(conn)
        assert query["error"] == "invalid_request"
        refute Map.has_key?(query, "code")
      end
    end
  end

  # ── OAUTH-05 ──────────────────────────────────────────────────────────────

  describe "choosing a firm" do
    @tag spec: "OAUTH-05"
    test "a person in two entities chooses one, and the token carries that one" do
      {user, _session, cookie} = signed_in("two-firms@firm.test")
      alpha = entity!("alpha-ventures", user.didi_id)
      beta = entity!("beta-capital", user.didi_id)
      {:ok, outsider} = Accounts.create_user(%{primary_email: "outsider@firm.test"})
      gamma = entity!("gamma-partners", outsider.didi_id)

      client_id = client!()
      {verifier, challenge} = pkce()
      params = authorize_params(client_id, challenge)

      html = get_authorize(cookie, params) |> html_response(200)
      assert html =~ alpha.name
      assert html =~ beta.name
      refute html =~ gamma.name

      # A firm they are not in is refused, whatever the form says.
      conn = approve(cookie, params, gamma.id)
      refute match?({_, %{"code" => _}}, conn.status == 302 && redirect_query(conn))

      {_uri, query} = approve(cookie, params, beta.id) |> redirect_query()
      assert query["state"] == "state-123"
      assert is_binary(query["code"])

      body =
        token(%{
          "grant_type" => "authorization_code",
          "code" => query["code"],
          "redirect_uri" => @claude_cb,
          "client_id" => client_id,
          "code_verifier" => verifier,
          "resource" => @memopop
        })
        |> json_response(200)

      {true, _header, claims} = verify_against_jwks(body["access_token"])
      assert claims["entity"] == %{"id" => beta.id, "slug" => beta.slug}
    end
  end

  # ── OAUTH-06 ──────────────────────────────────────────────────────────────

  describe "token exchange" do
    @tag spec: "OAUTH-06"
    test "the right verifier returns an access token for the resource, verifiable via JWKS" do
      flow = code_flow()
      conn = exchange(flow)
      body = json_response(conn, 200)

      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert body["token_type"] == "Bearer"
      assert body["expires_in"] == 3600
      assert is_binary(body["refresh_token"])

      {verified?, header, claims} = verify_against_jwks(body["access_token"])
      assert verified?
      assert header["alg"] == "EdDSA"
      assert header["kid"] == IdDidiSh.Keys.kid()
      assert header["typ"] == "at+jwt"

      assert claims["aud"] == @memopop
      assert claims["sub"] == flow.user.didi_id
      assert claims["entity"] == %{"id" => flow.entity.id, "slug" => flow.entity.slug}
      assert claims["client_id"] == flow.client_id
      assert claims["iss"] == Application.get_env(:id_didi_sh, :identity)[:issuer]
      assert claims["exp"] - claims["iat"] == 3600
      assert is_binary(claims["scope"])
      assert is_binary(claims["jti"])

      # An access token is not a session: it cannot stand in for didi_session.
      conn =
        build_conn() |> put_req_cookie("didi_session", body["access_token"]) |> get("/api/me")

      assert json_response(conn, 401)
    end

    @tag spec: "OAUTH-06"
    test "a wrong verifier is refused" do
      flow = code_flow()
      {wrong, _} = pkce()
      conn = exchange(flow, %{"code_verifier" => wrong})
      assert %{"error" => "invalid_grant"} = json_response(conn, 400)
      refute Map.has_key?(json_response(conn, 400), "access_token")

      # No verifier at all is refused the same way.
      flow = code_flow()

      conn =
        token(%{
          "grant_type" => "authorization_code",
          "code" => flow.code,
          "redirect_uri" => @claude_cb,
          "client_id" => flow.client_id
        })

      assert %{"error" => "invalid_grant"} = json_response(conn, 400)
    end
  end

  # ── OAUTH-07 ──────────────────────────────────────────────────────────────

  describe "authorization codes" do
    @tag spec: "OAUTH-07"
    test "a code works once; a second use is refused" do
      flow = code_flow()
      assert %{"access_token" => _} = json_response(exchange(flow), 200)
      assert %{"error" => "invalid_grant"} = json_response(exchange(flow), 400)
    end

    @tag spec: "OAUTH-07"
    test "codes are stored only as hashes" do
      flow = code_flow()

      raw_hits =
        IdDidiSh.Repo.query!(
          "SELECT count(*) FROM oauth_authorization_codes WHERE code_hash = ?",
          [flow.code]
        )

      assert raw_hits.rows == [[0]]

      hashed =
        IdDidiSh.Repo.query!(
          "SELECT count(*) FROM oauth_authorization_codes WHERE code_hash = ?",
          [:crypto.hash(:sha256, flow.code)]
        )

      assert hashed.rows == [[1]]
    end
  end

  # ── OAUTH-08 ──────────────────────────────────────────────────────────────

  describe "refresh" do
    @tag spec: "OAUTH-08"
    test "a refresh token returns a new pair; reusing the old one is refused and revokes the family" do
      flow = code_flow()
      first = json_response(exchange(flow), 200)

      second = json_response(refresh(flow.client_id, first["refresh_token"]), 200)
      assert is_binary(second["access_token"])
      assert is_binary(second["refresh_token"])
      assert second["refresh_token"] != first["refresh_token"]
      assert second["access_token"] != first["access_token"]

      {true, _h, claims} = verify_against_jwks(second["access_token"])
      assert claims["aud"] == @memopop
      assert claims["entity"] == %{"id" => flow.entity.id, "slug" => flow.entity.slug}

      # Replay of the rotated-out token: refused, with the RFC 6749 code
      # Claude expects...
      conn = refresh(flow.client_id, first["refresh_token"])
      assert %{"error" => "invalid_grant"} = json_response(conn, 400)

      # ...and the whole family is dead, including the newest token.
      conn = refresh(flow.client_id, second["refresh_token"])
      assert %{"error" => "invalid_grant"} = json_response(conn, 400)
    end

    @tag spec: "OAUTH-08"
    test "refresh tokens are stored only as hashes, and bound to their client" do
      flow = code_flow()
      %{"refresh_token" => rt} = json_response(exchange(flow), 200)

      raw_hits =
        IdDidiSh.Repo.query!("SELECT count(*) FROM oauth_refresh_tokens WHERE token_hash = ?", [
          rt
        ])

      assert raw_hits.rows == [[0]]

      other_client = client!()
      assert %{"error" => "invalid_grant"} = json_response(refresh(other_client, rt), 400)
    end
  end

  # ── OAUTH-09 ──────────────────────────────────────────────────────────────

  describe "session revocation" do
    @tag spec: "OAUTH-09"
    test "revoking the didi.sh session makes its refresh tokens fail" do
      flow = code_flow()
      %{"refresh_token" => rt} = json_response(exchange(flow), 200)

      # Sign out through the public API — the same path a person uses.
      conn = build_conn() |> put_req_cookie("didi_session", flow.cookie) |> delete("/api/session")
      assert %{"status" => "signed_out"} = json_response(conn, 200)

      assert %{"error" => "invalid_grant"} = json_response(refresh(flow.client_id, rt), 400)
    end
  end

  # ── OAUTH-10 ──────────────────────────────────────────────────────────────

  describe "audience binding" do
    @tag spec: "OAUTH-10"
    test "a token for one resource is never issued with another resource's audience" do
      # Authorized for MemoPop; the exchange asks for DidiDecks.
      flow = code_flow(resource: @memopop)
      conn = exchange(flow, %{"resource" => @decks})
      assert %{"error" => "invalid_target"} = json_response(conn, 400)

      # The same code, asked for honestly, is still MemoPop's (the refused
      # attempt did not burn it into a DidiDecks token).
      body = json_response(exchange(flow), 200)
      {true, _h, claims} = verify_against_jwks(body["access_token"])
      assert claims["aud"] == @memopop
      refute claims["aud"] == @decks

      # Refresh cannot switch audience either.
      conn = refresh(flow.client_id, body["refresh_token"], %{"resource" => @decks})
      assert %{"error" => "invalid_target"} = json_response(conn, 400)

      # A DidiDecks authorization gets a DidiDecks audience.
      decks = code_flow(resource: @decks)
      body = json_response(exchange(decks), 200)
      {true, _h, claims} = verify_against_jwks(body["access_token"])
      assert claims["aud"] == @decks
    end

    @tag spec: "OAUTH-10"
    test "a resource under a registered one (the MCP path) is audienced as the registered resource" do
      # Claude sends the MCP server URL as the user typed it, path included
      # (https://memopop.didi.sh/mcp). MemoPop verifies aud == its origin, so
      # the audience is the registered resource, never the raw path.
      flow = code_flow(resource: @memopop <> "/mcp")
      body = json_response(exchange(flow), 200)
      {true, _h, claims} = verify_against_jwks(body["access_token"])
      assert claims["aud"] == @memopop

      # Still cannot be swapped to another registered resource at the token step.
      flow = code_flow(resource: @memopop <> "/mcp")

      assert %{"error" => "invalid_target"} =
               json_response(exchange(flow, %{"resource" => @decks}), 400)
    end
  end

  test "the consent screen is the only thing authorize renders for a signed-in person" do
    # Guard: an anonymous POST to authorize can't mint a code.
    client_id = client!()
    {_v, challenge} = pkce()
    conn = post(build_conn(), "/oauth/authorize", authorize_params(client_id, challenge))
    refute match?({_, %{"code" => _}}, conn.status == 302 && redirect_query(conn))
    assert_no_email_sent()
  end
end
