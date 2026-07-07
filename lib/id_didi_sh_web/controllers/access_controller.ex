defmodule IdDidiShWeb.AccessController do
  use IdDidiShWeb, :controller

  alias IdDidiSh.Accounts
  alias IdDidiSh.Token
  alias IdDidiShWeb.SessionCookie

  @moduledoc """
  The hosted magic-link landing — the minimal fallback page the emails
  point at (`/access?token=…`). Deliberately two-step: the GET renders a
  confirm button and does NOT touch the token, so mail-scanner prefetch
  can't consume a single-use link; only the explicit POST redeems.

  This page stays minimal on purpose (the GTM headless contract: real
  sign-in UIs live in the apps). It exists for the click-from-email path
  and edge cases with no app context.
  """

  def show(conn, params) do
    render(conn, :show, token: params["token"], error: nil)
  end

  def redeem(conn, %{"token" => raw}) do
    case Accounts.redeem_magic_link(raw) do
      {:ok, user, login_token} ->
        session =
          Accounts.create_session(user, %{
            user_agent: conn |> get_req_header("user-agent") |> List.first()
          })

        Accounts.record_event("sign_in", %{
          didi_id: user.didi_id,
          app_slug: login_token.app_slug,
          payload: %{"method" => "magic_link", "surface" => "access_page"}
        })

        jwt = Token.sign(user.didi_id, session.id)
        conn = SessionCookie.put(conn, jwt)

        case safe_next(login_token.next_path) do
          nil -> render(conn, :done, email: user.primary_email)
          next -> redirect(conn, external: next)
        end

      {:error, :invalid_token} ->
        render(conn, :show,
          token: nil,
          error:
            "That link is invalid or expired — they're single-use and short-lived. Request a fresh one from the app you were signing into."
        )
    end
  end

  def redeem(conn, _params), do: redirect(conn, to: ~p"/access")

  # Only same-site relative paths or *.didi.sh URLs — never an open redirect.
  defp safe_next(nil), do: nil
  defp safe_next("/" <> _ = path), do: path

  defp safe_next(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        if host == "didi.sh" or String.ends_with?(host, ".didi.sh"), do: url, else: nil

      _ ->
        nil
    end
  end
end
