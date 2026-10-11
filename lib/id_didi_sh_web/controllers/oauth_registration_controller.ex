defmodule IdDidiShWeb.OAuthRegistrationController do
  use IdDidiShWeb, :controller

  @moduledoc """
  `POST /oauth/register` — RFC 7591 Dynamic Client Registration.

  Claude registers itself here on each fresh connection (it falls back to
  DCR whenever the metadata does not advertise Client ID Metadata Documents).
  Open by design: a registered client can do nothing until a signed-in
  person approves it on the consent screen, and its redirect URIs are held
  to an allowlist (Claude's callback, loopback for Claude Code).
  """

  alias IdDidiSh.OAuth

  def create(conn, _params) do
    # Phoenix merges path/query params in; registration metadata is the body.
    case OAuth.register_client(conn.body_params) do
      {:ok, response} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_status(:created)
        |> json(response)

      {:error, error, description} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: error, error_description: description})
    end
  end
end
