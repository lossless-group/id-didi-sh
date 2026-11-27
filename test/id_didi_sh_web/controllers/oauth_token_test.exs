defmodule IdDidiShWeb.OAuthTokenTest do
  @moduledoc """
  `POST /oauth/token` — how a client authenticates and what every response
  carries, independent of the grant. The grants themselves are pinned in
  `oauth_test.exs` (OAUTH-01..10); this file covers the branches those flows
  never take: confidential clients over HTTP Basic, and the error envelope.
  """
  use IdDidiShWeb.ConnCase, async: false

  @claude_cb "https://claude.ai/api/mcp/auth_callback"

  defp register(method) do
    body = %{
      "client_name" => "Confidential",
      "redirect_uris" => [@claude_cb],
      "grant_types" => ["authorization_code", "refresh_token"],
      "response_types" => ["code"],
      "token_endpoint_auth_method" => method
    }

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/oauth/register", Jason.encode!(body))
    |> json_response(201)
  end

  defp token(conn \\ build_conn(), params) do
    conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> put_req_header("accept", "application/json")
    |> post("/oauth/token", URI.encode_query(params))
  end

  defp basic(conn \\ build_conn(), id, secret) do
    encoded =
      Base.encode64("#{URI.encode_www_form(id)}:#{URI.encode_www_form(secret)}")

    put_req_header(conn, "authorization", "Basic " <> encoded)
  end

  defp assert_no_store(conn) do
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "pragma") == ["no-cache"]
  end

  describe "client authentication over HTTP Basic (RFC 6749 §2.3.1)" do
    test "the right secret authenticates; the request then fails on the grant, not the client" do
      %{"client_id" => id, "client_secret" => secret} = register("client_secret_basic")

      conn = token(basic(id, secret), %{})

      assert %{"error" => "invalid_request"} = json_response(conn, 400)
      assert_no_store(conn)
    end

    test "a wrong secret is invalid_client with a Basic challenge" do
      %{"client_id" => id} = register("client_secret_basic")

      conn = token(basic(id, "not-the-secret"), %{"grant_type" => "refresh_token"})

      assert %{"error" => "invalid_client"} = json_response(conn, 401)
      assert get_resp_header(conn, "www-authenticate") == [~s(Basic realm="id.didi.sh")]
      assert_no_store(conn)
    end

    test "a malformed Basic header falls back to the body credentials" do
      %{"client_id" => id, "client_secret" => secret} = register("client_secret_post")

      conn =
        build_conn()
        |> put_req_header("authorization", "Basic !!!not-base64")
        |> token(%{"client_id" => id, "client_secret" => secret})

      assert %{"error" => "invalid_request"} = json_response(conn, 400)
    end
  end

  describe "client authentication in the body" do
    test "a wrong body secret is invalid_client with NO Basic challenge" do
      %{"client_id" => id} = register("client_secret_post")

      conn = token(%{"client_id" => id, "client_secret" => "wrong", "grant_type" => "x"})

      assert %{"error" => "invalid_client"} = json_response(conn, 401)
      assert get_resp_header(conn, "www-authenticate") == []
    end

    test "a confidential client that sends no secret at all is refused" do
      %{"client_id" => id} = register("client_secret_post")

      conn = token(%{"client_id" => id, "grant_type" => "refresh_token"})

      assert %{"error" => "invalid_client"} = json_response(conn, 401)
    end

    test "an unknown client is invalid_client" do
      conn = token(%{"client_id" => "nobody", "grant_type" => "refresh_token"})

      assert %{"error" => "invalid_client", "error_description" => "unknown client"} =
               json_response(conn, 401)

      assert_no_store(conn)
    end
  end

  describe "grant_type" do
    setup do
      %{"client_id" => id} = register("none")
      %{client_id: id}
    end

    test "missing is invalid_request", %{client_id: id} do
      conn = token(%{"client_id" => id})
      assert %{"error" => "invalid_request"} = json_response(conn, 400)
    end

    test "anything but the two supported grants is unsupported_grant_type", %{client_id: id} do
      for grant <- ["client_credentials", "password", "implicit"] do
        conn = token(%{"client_id" => id, "grant_type" => grant})
        assert %{"error" => "unsupported_grant_type"} = json_response(conn, 400)
        assert_no_store(conn)
      end
    end
  end
end
