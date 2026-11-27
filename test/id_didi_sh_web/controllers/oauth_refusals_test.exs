defmodule IdDidiShWeb.OAuthRefusalsTest do
  @moduledoc """
  Every reason the token endpoint refuses a grant. `oauth_test.exs` proves
  the flows work (OAUTH-01..10); this file proves each refusal fires, with the
  RFC 6749 §5.2 code Claude acts on. `invalid_grant` means "sign in again" to
  Claude, so it must be exactly that code, every time.
  """
  use IdDidiShWeb.ConnCase, async: false

  import Ecto.Query

  alias IdDidiSh.{Accounts, Entities, Repo, Token}
  alias IdDidiSh.OAuth.{AuthorizationCode, RefreshToken}

  @claude_cb "https://claude.ai/api/mcp/auth_callback"
  @memopop "https://memopop.didi.sh"

  # ── the browser half, as in oauth_test.exs ───────────────────────────────

  defp client! do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(
      "/oauth/register",
      Jason.encode!(%{
        "client_name" => "Claude",
        "redirect_uris" => [@claude_cb],
        "grant_types" => ["authorization_code", "refresh_token"],
        "response_types" => ["code"],
        "token_endpoint_auth_method" => "none"
      })
    )
    |> json_response(201)
    |> Map.fetch!("client_id")
  end

  defp code_flow do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.create_user(%{primary_email: "p#{n}@firm.test", name: "P"})
    session = Accounts.create_session(user)
    cookie = Token.sign(user.didi_id, session.id)

    {:ok, entity} =
      Entities.create_entity(%{"kind" => "organization", "slug" => "f#{n}", "name" => "F"})

    {:ok, _} = Entities.add_member(entity.id, user.didi_id, "viewer", via: "seed")
    client_id = client!()
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    params = %{
      "response_type" => "code",
      "client_id" => client_id,
      "redirect_uri" => @claude_cb,
      "code_challenge" => challenge,
      "code_challenge_method" => "S256",
      "state" => "s",
      "scope" => "offline_access",
      "resource" => @memopop,
      "entity_id" => entity.id,
      "decision" => "approve"
    }

    conn =
      build_conn() |> put_req_cookie("didi_session", cookie) |> post("/oauth/authorize", params)

    %{"code" => code} =
      conn |> redirected_to(302) |> URI.parse() |> Map.get(:query) |> URI.decode_query()

    %{
      user: user,
      session: session,
      entity: entity,
      client_id: client_id,
      verifier: verifier,
      code: code
    }
  end

  defp token(params) do
    build_conn()
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post("/oauth/token", URI.encode_query(params))
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
          "resource" => @memopop
        },
        overrides
      )
    )
  end

  defp refresh(client_id, rt, overrides \\ %{}) do
    token(
      Map.merge(
        %{"grant_type" => "refresh_token", "refresh_token" => rt, "client_id" => client_id},
        overrides
      )
    )
  end

  defp refused(conn, code \\ "invalid_grant") do
    body = json_response(conn, 400)
    assert body["error"] == code, "expected #{code}, got #{inspect(body)}"
    body["error_description"]
  end

  defp past, do: DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)
  defp hash(raw), do: :crypto.hash(:sha256, raw)

  defp tokens!(flow) do
    exchange(flow) |> json_response(200)
  end

  # ── authorization codes ──────────────────────────────────────────────────

  describe "the code exchange refuses" do
    test "a missing code (invalid_request) and an unknown one (invalid_grant)" do
      flow = code_flow()

      assert refused(exchange(flow, %{"code" => ""}), "invalid_request") == "code is required"
      assert refused(exchange(flow, %{"code" => "made-up"})) == "unknown authorization code"
    end

    test "an expired code" do
      flow = code_flow()

      Repo.update_all(where(AuthorizationCode, code_hash: ^hash(flow.code)),
        set: [expires_at: past()]
      )

      assert refused(exchange(flow)) == "authorization code expired"
    end

    test "a code presented by a different client" do
      flow = code_flow()
      other = client!()

      assert refused(exchange(flow, %{"client_id" => other})) ==
               "code was issued to another client"
    end

    test "a redirect_uri that differs from the authorization request" do
      flow = code_flow()

      assert refused(exchange(flow, %{"redirect_uri" => "http://localhost:9999/cb"})) ==
               "redirect_uri does not match the authorization request"
    end

    test "a code whose consenting session has since ended" do
      flow = code_flow()
      Accounts.revoke_session(flow.session.id)

      assert refused(exchange(flow)) == "the didi.sh session that consented has ended"
    end

    test "a refused attempt does not burn the code" do
      flow = code_flow()
      refused(exchange(flow, %{"redirect_uri" => "http://localhost:9999/cb"}))

      assert %{"access_token" => _} = tokens!(flow)
    end
  end

  # ── refresh tokens ───────────────────────────────────────────────────────

  describe "refresh refuses" do
    test "a missing token (invalid_request) and an unknown one (invalid_grant)" do
      flow = code_flow()

      assert refused(refresh(flow.client_id, ""), "invalid_request") ==
               "refresh_token is required"

      assert refused(refresh(flow.client_id, "made-up")) == "unknown refresh token"
    end

    test "a token presented by a different client" do
      flow = code_flow()
      %{"refresh_token" => rt} = tokens!(flow)

      assert refused(refresh(client!(), rt)) == "refresh token was issued to another client"
    end

    test "an expired token" do
      flow = code_flow()
      %{"refresh_token" => rt} = tokens!(flow)
      Repo.update_all(where(RefreshToken, token_hash: ^hash(rt)), set: [expires_at: past()])

      assert refused(refresh(flow.client_id, rt)) == "refresh token expired"
    end

    test "a different resource than the grant (invalid_target)" do
      flow = code_flow()
      %{"refresh_token" => rt} = tokens!(flow)

      assert refused(
               refresh(flow.client_id, rt, %{"resource" => "https://decks.didi.sh"}),
               "invalid_target"
             ) =~
               "resource does not match"
    end

    test "after the person is removed from the entity, and the whole family dies" do
      flow = code_flow()
      %{"refresh_token" => rt} = tokens!(flow)
      :ok = Entities.remove_member(flow.entity.id, flow.user.didi_id)

      assert refused(refresh(flow.client_id, rt)) == "no longer a member of that entity"

      # Re-adding them does not resurrect a revoked grant.
      {:ok, _} = Entities.add_member(flow.entity.id, flow.user.didi_id, "viewer", via: "seed")
      assert refused(refresh(flow.client_id, rt)) == "refresh token revoked"
    end
  end
end
