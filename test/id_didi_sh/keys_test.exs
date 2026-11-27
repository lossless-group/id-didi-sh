defmodule IdDidiSh.KeysTest do
  @moduledoc """
  Signing-key resolution. The key is cached in `:persistent_term` and read
  from env and application config, so every test here resets all three and
  the module runs `async: false`.
  """
  use ExUnit.Case, async: false

  alias IdDidiSh.Keys

  @cache {Keys, :jwk}

  setup do
    original_identity = Application.get_env(:id_didi_sh, :identity)
    original_env = System.get_env("ID_SIGNING_JWK")
    original_cache = :persistent_term.get(@cache, nil)

    :persistent_term.erase(@cache)

    on_exit(fn ->
      Application.put_env(:id_didi_sh, :identity, original_identity)

      if original_env,
        do: System.put_env("ID_SIGNING_JWK", original_env),
        else: System.delete_env("ID_SIGNING_JWK")

      if original_cache,
        do: :persistent_term.put(@cache, original_cache),
        else: :persistent_term.erase(@cache)
    end)

    :ok
  end

  defp generated_jwk_json do
    {_meta, map} = JOSE.JWK.generate_key({:okp, :Ed25519}) |> JOSE.JWK.to_map()
    {map, Jason.encode!(map)}
  end

  defp disallow_dev_keys do
    identity = Application.get_env(:id_didi_sh, :identity)
    Application.put_env(:id_didi_sh, :identity, Keyword.put(identity, :allow_dev_keys, false))
  end

  test "ID_SIGNING_JWK wins over the dev key, even where dev keys are allowed" do
    {map, json} = generated_jwk_json()
    System.put_env("ID_SIGNING_JWK", json)

    assert Keys.public_jwk_map()["x"] == map["x"]
  end

  test "production posture: no env key and no dev keys raises with the way out" do
    System.delete_env("ID_SIGNING_JWK")
    disallow_dev_keys()

    error = assert_raise RuntimeError, fn -> Keys.signing_jwk() end
    assert error.message =~ "ID_SIGNING_JWK is not set"
    assert error.message =~ "mix id.gen.keypair"
  end

  test "the key is cached after first resolution" do
    {_map, json} = generated_jwk_json()
    System.put_env("ID_SIGNING_JWK", json)
    first = Keys.kid()

    # A different env key after caching must not change what is served.
    {_map2, json2} = generated_jwk_json()
    System.put_env("ID_SIGNING_JWK", json2)

    assert Keys.kid() == first
  end

  test "kid is the RFC 7638 thumbprint, and the public JWK carries no private material" do
    {_map, json} = generated_jwk_json()
    System.put_env("ID_SIGNING_JWK", json)

    public = Keys.public_jwk_map()

    assert public["kid"] == JOSE.JWK.thumbprint(Keys.signing_jwk())
    assert public["alg"] == "EdDSA"
    assert public["use"] == "sig"
    assert public["kty"] == "OKP"
    refute Map.has_key?(public, "d")
    assert Keys.jwks() == %{"keys" => [public]}
  end

  test "the dev key is generated once and then reused from disk" do
    System.delete_env("ID_SIGNING_JWK")

    # Start from no key file, so the generate branch runs; put the original
    # back afterwards so a dev's local key survives the test run.
    path = Application.app_dir(:id_didi_sh, Path.join(["priv", "keys", "dev_signing.jwk"]))
    backup = if File.exists?(path), do: File.read!(path)
    File.rm(path)

    on_exit(fn ->
      if backup, do: File.write!(path, backup), else: File.rm(path)
    end)

    first = Keys.kid()
    assert File.exists?(path)

    :persistent_term.erase(@cache)
    assert Keys.kid() == first
  end
end
