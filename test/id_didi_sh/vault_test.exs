defmodule IdDidiSh.VaultTest do
  @moduledoc """
  The key that encrypts lent API keys at rest.

  Until 2026-11-26 nothing set `config :id_didi_sh, :env`, so `prod?/0` was
  always false and production quietly encrypted with the dev key, which is in
  this repo in plain text. These tests pin both halves: the env is actually
  configured, and in prod a missing or malformed key stops the boot.

  `async: false` because they change application env and OS env.
  """
  use ExUnit.Case, async: false

  alias IdDidiSh.Vault

  @dev_key :crypto.hash(:sha256, "id-didi-sh-dev-credential-key")

  setup do
    original_env = Application.get_env(:id_didi_sh, :env)
    original_key = System.get_env("CREDENTIAL_ENCRYPTION_KEY")

    on_exit(fn ->
      Application.put_env(:id_didi_sh, :env, original_env)

      if original_key,
        do: System.put_env("CREDENTIAL_ENCRYPTION_KEY", original_key),
        else: System.delete_env("CREDENTIAL_ENCRYPTION_KEY")
    end)
  end

  defp key_in({:ok, config}) do
    {Cloak.Ciphers.AES.GCM, opts} = config[:ciphers][:default]
    opts[:key]
  end

  test "the env is configured, so the prod check can ever be true" do
    assert Application.get_env(:id_didi_sh, :env) == :test
  end

  test "prod with no key refuses to boot" do
    Application.put_env(:id_didi_sh, :env, :prod)
    System.delete_env("CREDENTIAL_ENCRYPTION_KEY")

    error = assert_raise RuntimeError, fn -> Vault.init([]) end
    assert error.message =~ "CREDENTIAL_ENCRYPTION_KEY is missing"
  end

  test "prod never falls back to the dev key" do
    Application.put_env(:id_didi_sh, :env, :prod)
    key = :crypto.strong_rand_bytes(32)
    System.put_env("CREDENTIAL_ENCRYPTION_KEY", Base.encode64(key))

    assert key_in(Vault.init([])) == key
    refute key_in(Vault.init([])) == @dev_key
  end

  test "a key that is not base64 of exactly 32 bytes is refused" do
    for bad <- ["not base64!!", Base.encode64(:crypto.strong_rand_bytes(16))] do
      System.put_env("CREDENTIAL_ENCRYPTION_KEY", bad)

      error = assert_raise RuntimeError, fn -> Vault.init([]) end
      assert error.message =~ "exactly 32 bytes"
    end
  end

  test "outside prod with no key, the deterministic dev key is used" do
    System.delete_env("CREDENTIAL_ENCRYPTION_KEY")
    assert key_in(Vault.init([])) == @dev_key
  end
end
