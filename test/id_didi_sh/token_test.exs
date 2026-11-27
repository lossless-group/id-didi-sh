defmodule IdDidiSh.TokenTest do
  @moduledoc """
  Session-token verification: what a consumer gets back for every token that
  is not a good one. `async: false` because one test changes the issuer.
  """
  use ExUnit.Case, async: false

  alias IdDidiSh.Token

  test "no token at all is :missing" do
    assert Token.verify(nil) == {:error, :missing}
    assert Token.verify(123) == {:error, :missing}
  end

  test "garbage is :malformed, not a crash" do
    assert Token.verify("not.a.jwt") == {:error, :malformed}
    assert Token.verify("") == {:error, :malformed}
  end

  test "a token signed by any other key is :bad_signature" do
    other = JOSE.JWK.generate_key({:okp, :Ed25519})

    forged =
      JOSE.JWT.sign(other, %{"alg" => "EdDSA"}, %{
        "sub" => "someone",
        "sid" => "s",
        "iss" => "http://localhost:4002",
        "exp" => System.system_time(:second) + 600
      })
      |> JOSE.JWS.compact()
      |> elem(1)

    assert Token.verify(forged) == {:error, :bad_signature}
  end

  test "a token from another issuer is :bad_issuer" do
    original = Application.get_env(:id_didi_sh, :identity)

    Application.put_env(
      :id_didi_sh,
      :identity,
      Keyword.put(original, :issuer, "https://elsewhere")
    )

    foreign = Token.sign("someone", "s")
    Application.put_env(:id_didi_sh, :identity, original)

    assert Token.verify(foreign) == {:error, :bad_issuer}
  end

  test "a correctly signed token missing its claims is :malformed" do
    jwk = IdDidiSh.Keys.signing_jwk()

    bare =
      JOSE.JWT.sign(jwk, %{"alg" => "EdDSA"}, %{"sub" => "someone"})
      |> JOSE.JWS.compact()
      |> elem(1)

    assert Token.verify(bare) == {:error, :malformed}
  end
end
