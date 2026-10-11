defmodule IdDidiShWeb.OAuthAuthorizeController do
  use IdDidiShWeb, :controller

  @moduledoc """
  `GET /oauth/authorize` and the consent decision, `POST /oauth/authorize`.

  **A deliberate, minimal extension of invariant 4 (headless-first).** An
  authorization server must host this page: Claude opens it in a browser and
  cannot render anyone's login. It is held to two things:

  1. **The sign-in hop.** No session → the existing `/auth` page, carrying a
     `return_to` back here. The magic link it sends lands on the existing
     `/access` page, which redirects back. No new sign-in code path exists.
  2. **One consent screen.** Which app is asking (its registered name, and
     the host it will send you back to), which product it wants (the
     resource), and which firm (entity) it will reach. A person in several
     entities picks one.

  The POST re-validates every parameter. The hidden fields are a convenience
  for the browser, never a source of trust.
  """

  alias IdDidiSh.{Accounts, OAuth, Token}
  alias IdDidiShWeb.SessionCookie

  def show(conn, params) do
    with_request(conn, params, fn conn, request ->
      case current_user(conn) do
        {:ok, user, _session} -> render_consent(conn, request, params, user, nil)
        :none -> send_to_sign_in(conn, params)
      end
    end)
  end

  def decide(conn, params) do
    with_request(conn, params, fn conn, request ->
      case current_user(conn) do
        :none ->
          send_to_sign_in(conn, params)

        {:ok, user, session} ->
          case params["decision"] do
            "approve" ->
              case OAuth.issue_code(request, user, session, params["entity_id"]) do
                {:ok, code} ->
                  back_to_client(conn, request.redirect_uri, %{
                    "code" => code,
                    "state" => request.state
                  })

                {:error, :entity_not_allowed} ->
                  conn
                  |> put_status(:bad_request)
                  |> render_consent(request, params, user, "Pick one of your firms below.")
              end

            _ ->
              back_to_client(conn, request.redirect_uri, %{
                "error" => "access_denied",
                "error_description" => "the person declined",
                "state" => request.state
              })
          end
      end
    end)
  end

  # ── plumbing ──────────────────────────────────────────────────────────────

  defp with_request(conn, params, fun) do
    case OAuth.validate_authorization_request(params) do
      {:ok, request} ->
        fun.(conn, request)

      {:error_page, message} ->
        conn
        |> put_status(:bad_request)
        |> render(:error, message: message)

      {:redirect_error, redirect_uri, state, error, description} ->
        back_to_client(conn, redirect_uri, %{
          "error" => error,
          "error_description" => description,
          "state" => state
        })
    end
  end

  # Same three-step check as the account page: signature, live session row,
  # user. A browser that is not signed in goes to sign-in, not to a 401.
  defp current_user(conn) do
    with token when is_binary(token) <- SessionCookie.read(conn),
         {:ok, claims} <- Token.verify(token),
         session when not is_nil(session) <- Accounts.get_live_session(claims.session_id),
         user when not is_nil(user) <- Accounts.get_user(claims.didi_id) do
      {:ok, user, session}
    else
      _ -> :none
    end
  end

  defp send_to_sign_in(conn, params) do
    return_to =
      "/oauth/authorize?" <> URI.encode_query(Map.take(params, OAuth.authorize_fields()))

    redirect(conn, to: "/auth?" <> URI.encode_query(%{"return_to" => return_to}))
  end

  # RFC 6749 §4.1.2 plus RFC 9207: the issuer rides along so a client talking
  # to several servers can tell whose answer this is.
  defp back_to_client(conn, redirect_uri, fields) do
    uri = URI.parse(redirect_uri)

    extra =
      fields
      |> Map.put("iss", OAuth.issuer())
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    query = URI.decode_query(uri.query || "") |> Map.merge(Map.new(extra))
    redirect(conn, external: URI.to_string(%{uri | query: URI.encode_query(query)}))
  end

  defp render_consent(conn, request, params, user, error) do
    target = URI.parse(request.redirect_uri)

    render(conn, :consent,
      page_title: "Allow #{request.client.client_name}",
      client_name: request.client.client_name,
      redirect_host: target.host,
      loopback?: OAuth.loopback?(request.redirect_uri),
      resource_name: request.resource.name,
      resource_uri: request.resource.uri,
      user: user,
      entities: OAuth.entity_choices(user.didi_id),
      hidden: Map.take(params, OAuth.authorize_fields()),
      selected: params["entity_id"],
      error: error
    )
  end
end
