defmodule IdDidiShWeb.OAuthMetadataController do
  use IdDidiShWeb, :controller

  @moduledoc """
  OAuth discovery: `/.well-known/oauth-authorization-server` (RFC 8414) and
  `/.well-known/openid-configuration` (OIDC Discovery 1.0).

  Every URL comes from the configured issuer (`IdDidiSh.OAuth.issuer/0`),
  never from `conn.scheme` / `conn.host`. Fly's proxy forwards plain http;
  a discovery document built from the request would advertise `http://`
  endpoints, and Claude fails with "Couldn't register with … sign-in
  service" (measured 2026-07-25 against Twenty behind Railway).
  """

  alias IdDidiSh.OAuth

  def authorization_server(conn, _params), do: send_doc(conn, OAuth.metadata())
  def openid_configuration(conn, _params), do: send_doc(conn, OAuth.openid_configuration())

  defp send_doc(conn, doc) do
    conn
    |> put_resp_header("cache-control", "public, max-age=300")
    |> json(doc)
  end
end
