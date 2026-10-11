defmodule IdDidiShWeb.OAuthTokenController do
  use IdDidiShWeb, :controller

  @moduledoc """
  `POST /oauth/token` — the code exchange and refresh grants.

  Takes `application/x-www-form-urlencoded` (RFC 6749 §4.1.3; Claude sends
  it for both grants). Errors are RFC 6749 §5.2 codes: Claude treats
  `invalid_grant` as "sign in again", so a dead refresh token must say
  exactly that and nothing custom.
  """

  alias IdDidiSh.OAuth

  def create(conn, params) do
    {client_id, secret, via_basic?} = client_credentials(conn, params)

    result =
      with {:ok, client} <- OAuth.authenticate_client(client_id, secret) do
        case params["grant_type"] do
          "authorization_code" -> OAuth.exchange_code(client, params)
          "refresh_token" -> OAuth.refresh(client, params)
          nil -> {:error, "invalid_request", "grant_type is required"}
          _ -> {:error, "unsupported_grant_type", "use authorization_code or refresh_token"}
        end
      end

    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("pragma", "no-cache")

    case result do
      {:ok, body} ->
        json(conn, body)

      {:error, "invalid_client", description} ->
        conn
        |> then(fn c ->
          if via_basic?,
            do: put_resp_header(c, "www-authenticate", ~s(Basic realm="id.didi.sh")),
            else: c
        end)
        |> put_status(:unauthorized)
        |> json(%{error: "invalid_client", error_description: description})

      {:error, error, description} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: error, error_description: description})
    end
  end

  # HTTP Basic first (RFC 6749 §2.3.1, components form-urlencoded), then the
  # body. Public clients send only client_id in the body.
  defp client_credentials(conn, params) do
    with ["Basic " <> encoded | _] <- get_req_header(conn, "authorization"),
         {:ok, decoded} <- Base.decode64(encoded),
         [id, secret] <- String.split(decoded, ":", parts: 2) do
      {URI.decode_www_form(id), URI.decode_www_form(secret), true}
    else
      _ -> {params["client_id"], params["client_secret"], false}
    end
  end
end
