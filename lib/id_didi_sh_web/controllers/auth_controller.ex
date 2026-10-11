defmodule IdDidiShWeb.AuthController do
  use IdDidiShWeb, :controller

  alias IdDidiSh.Accounts

  @moduledoc """
  The hosted sign-in page — `GET /auth`.

  **This is a deliberate softening of the headless posture.** `AccessController`
  says real sign-in UIs live in the apps, and that stays true: an app that has
  its own login screen should keep calling `POST /api/magic-links` and never send
  anyone here. But didi.sh and the splash both advertise "one login" with no way
  to perform one, and a marketing site whose call-to-action has no destination is
  worse than one with no call-to-action.

  So this is the front door for the case with no app context: somebody arriving
  from didi.sh who wants in. It issues the same magic link the API issues and
  hands off to `/access`, which already does the redemption. Nothing new is
  minted, no second code path exists.

  **Never reveals whether an account exists.** Same invite-only posture as the
  API: every submission renders the same "check your email" page whether or not
  the address is known, because a different answer is an enumeration oracle.
  """

  def new(conn, params) do
    render(conn, :new, email: nil, error: nil, return_to: return_to(params))
  end

  def create(conn, %{"email" => email} = params) when is_binary(email) do
    trimmed = String.trim(email)
    return_to = return_to(params)

    if trimmed == "" or not String.contains?(trimmed, "@") do
      render(conn, :new,
        email: trimmed,
        error: "That does not look like an email address.",
        return_to: return_to
      )
    else
      # Fire and forget, deliberately: the page below says the same thing
      # whatever this returns.
      case Accounts.issue_magic_link(trimmed, app_slug: "didi-sh", next_path: return_to) do
        {:ok, raw, _token} ->
          Accounts.record_event("magic_link_issued", %{app_slug: "didi-sh"})
          deliver(trimmed, raw)

        {:ok, :noop} ->
          :ok
      end

      render(conn, :sent, email: trimmed)
    end
  end

  def create(conn, params) do
    render(conn, :new,
      email: nil,
      error: "Enter the email you were invited with.",
      return_to: return_to(params)
    )
  end

  # The OAuth sign-in hop: /oauth/authorize sends a signed-out person here
  # with the way back, and the magic link carries it to /access. Only the
  # authorize endpoint is a valid way back. Anything else is dropped, so this
  # page can never be used to bounce someone to an arbitrary destination.
  defp return_to(%{"return_to" => "/oauth/authorize?" <> _ = path}), do: path
  defp return_to(_), do: nil

  defp deliver(email, raw_token) do
    IdDidiSh.Accounts.MagicLinkNotifier.deliver(email, raw_token)
  rescue
    # Same rule as the API path: delivery must never break the flow, and the
    # page has already promised nothing it cannot keep.
    _ -> :ok
  end
end
