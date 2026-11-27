defmodule IdDidiShWeb.ApiRefusalsTest do
  @moduledoc """
  The headless API's refusals: what a consumer app's own login UI gets back
  when it sends nothing, sends garbage, or sends a forged cookie.
  """
  use IdDidiShWeb.ConnCase, async: false

  defp forged_cookie do
    other = JOSE.JWK.generate_key({:okp, :Ed25519})

    JOSE.JWT.sign(other, %{"alg" => "EdDSA"}, %{
      "sub" => "someone",
      "sid" => "s",
      "iss" => "http://localhost:4002",
      "exp" => System.system_time(:second) + 600
    })
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  describe "POST /api/magic-links" do
    test "without an email is 400" do
      assert json_response(post(build_conn(), "/api/magic-links", %{}), 400) ==
               %{"error" => "email is required"}
    end
  end

  describe "POST /api/magic-links/redeem" do
    test "without a token is 400; with an unknown one is 401" do
      assert json_response(post(build_conn(), "/api/magic-links/redeem", %{}), 400) ==
               %{"error" => "token is required"}

      assert json_response(
               post(build_conn(), "/api/magic-links/redeem", %{"token" => "made-up"}),
               401
             ) == %{"error" => "invalid or expired token"}
    end
  end

  describe "the session endpoints with a forged cookie" do
    test "refresh refuses it" do
      conn =
        build_conn()
        |> put_req_cookie("didi_session", forged_cookie())
        |> post("/api/session/refresh")

      assert json_response(conn, 401)
    end

    test "logout still clears the cookie and revokes nothing" do
      conn =
        build_conn()
        |> put_req_cookie("didi_session", forged_cookie())
        |> delete("/api/session")

      assert json_response(conn, 200) == %{"status" => "signed_out"}
      assert conn.resp_cookies["didi_session"][:max_age] == 0
    end
  end
end
