defmodule IdDidiShWeb.AccountController do
  use IdDidiShWeb, :controller

  alias IdDidiSh.Accounts
  alias IdDidiSh.Token
  alias IdDidiShWeb.SessionCookie

  @moduledoc """
  `GET /account` — what the credential actually resolves to.

  Sign-in used to end at "your session is live, close this page", which is true
  and unverifiable. The first question anyone has after signing in is *did it
  work* — meaning: which identity am I, which entities do I belong to, and is
  the signing key resolving. This page answers those three and nothing else.

  It is the browser view of `GET /api/me`, plus the token check the API performs
  and does not report. Same data, same source; no second notion of identity.

  **Auth is checked here rather than by `Plugs.RequireUser`**, which halts with
  a JSON 401 — correct for the API scope it was written for, wrong for a browser
  page, where the answer to "not signed in" is the sign-in page.
  """

  def show(conn, _params) do
    with token when is_binary(token) <- SessionCookie.read(conn),
         {:ok, claims} <- Token.verify(token),
         session when not is_nil(session) <- Accounts.get_live_session(claims.session_id),
         user when not is_nil(user) <- Accounts.get_user(claims.didi_id) do
      render(conn, :show,
        user: user,
        session: session,
        alt_emails: Accounts.list_email_aliases(user.didi_id),
        entities: entities_for(user.didi_id),
        # The token in hand verified a moment ago, which is exactly the claim a
        # consumer makes when it verifies locally against the JWKS. Reporting it
        # is the difference between "you are signed in" and "here is the check
        # that says so".
        token_verified: true,
        jwks_url: jwks_url(conn)
      )
    else
      _ -> redirect(conn, to: ~p"/auth")
    end
  end

  # A membership names an org id; the page wants something a person recognises.
  # A row with no organization still renders — an id with no name is a real
  # state and hiding it would make a broken membership look like no membership.
  defp entities_for(didi_id) do
    didi_id
    |> Accounts.memberships_for()
    |> Enum.map(fn m ->
      org = Accounts.get_org(m.org_id)

      %{
        id: m.org_id,
        role: m.role,
        name: org && org.name,
        slug: org && org.slug
      }
    end)
  end

  defp jwks_url(conn), do: "#{conn.scheme}://#{conn.host}/.well-known/jwks.json"
end
