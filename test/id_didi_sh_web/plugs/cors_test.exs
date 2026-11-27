defmodule IdDidiShWeb.Plugs.CORSTest do
  @moduledoc """
  The CORS allowlist is the trust boundary for browser callers: an origin on
  the list gets its own origin echoed back with credentials, and every other
  origin gets nothing at all. `*` must never appear, because credentials are
  always allowed for a matched origin.

  `async: false` because the allowlist is read from application env.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias IdDidiShWeb.Plugs.CORS

  @listed "https://augment.didi.sh"
  @unlisted "https://evil.example"

  setup do
    original = Application.get_env(:id_didi_sh, :identity)

    Application.put_env(
      :id_didi_sh,
      :identity,
      Keyword.put(original, :cors_origins, [@listed])
    )

    on_exit(fn -> Application.put_env(:id_didi_sh, :identity, original) end)
  end

  defp call(method, origin) do
    conn = conn(method, "/api/me")
    conn = if origin, do: put_req_header(conn, "origin", origin), else: conn
    CORS.call(conn, CORS.init([]))
  end

  defp cors_headers(conn) do
    Enum.filter(conn.resp_headers, fn {k, _} -> String.starts_with?(k, "access-control-") end)
  end

  test "a listed origin is echoed exactly, with credentials, and varies on origin" do
    conn = call(:get, @listed)

    assert get_resp_header(conn, "access-control-allow-origin") == [@listed]
    assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]
    assert get_resp_header(conn, "vary") == ["origin"]
    refute conn.halted
  end

  test "an unlisted origin gets no CORS headers at all" do
    conn = call(:get, @unlisted)

    assert cors_headers(conn) == []
    refute conn.halted
  end

  test "a request with no Origin header passes through untouched" do
    conn = call(:get, nil)

    assert cors_headers(conn) == []
    refute conn.halted
  end

  test "a preflight from a listed origin is answered 204 and halted" do
    conn = call(:options, @listed)

    assert conn.status == 204
    assert conn.halted
    assert get_resp_header(conn, "access-control-allow-origin") == [@listed]
    assert get_resp_header(conn, "access-control-allow-methods") == ["GET, POST, DELETE, OPTIONS"]
    assert get_resp_header(conn, "access-control-allow-headers") == ["content-type"]
    assert get_resp_header(conn, "access-control-max-age") == ["600"]
  end

  test "a preflight from an unlisted origin is not answered by CORS" do
    conn = call(:options, @unlisted)

    assert cors_headers(conn) == []
    refute conn.halted
    assert conn.state == :unset
  end

  test "with no allowlist configured, nothing is allowed" do
    Application.put_env(
      :id_didi_sh,
      :identity,
      Keyword.delete(Application.get_env(:id_didi_sh, :identity), :cors_origins)
    )

    assert cors_headers(call(:get, @listed)) == []
  end

  test "the wildcard never appears, even for a listed origin" do
    for method <- [:get, :options] do
      refute get_resp_header(call(method, @listed), "access-control-allow-origin") == ["*"]
    end
  end
end
