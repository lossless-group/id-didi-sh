defmodule IdDidiShWeb.WorkspaceController do
  @moduledoc """
  GET /api/workspaces — every workspace the caller may touch, with their role.

  What makes this endpoint worth having is what it does NOT do: it never looks at
  the caller's email domain. The list comes from membership grants, so one login
  shows reach-edu, palmer-ai and lossless side by side even though each was set
  up under a different address.

  `joinable` is a separate field on purpose. Those are workspaces the caller
  could *let themselves into* on the strength of their domain — an offer, not
  access. Collapsing the two lists would rebuild exactly the domain-derived
  model the 2026-08-09 amendment removed.
  """

  use IdDidiShWeb, :controller

  alias IdDidiSh.Accounts
  alias IdDidiSh.Token
  alias IdDidiSh.Workspaces
  alias IdDidiShWeb.SessionCookie

  def index(conn, _params) do
    with token when is_binary(token) <- SessionCookie.read(conn),
         {:ok, claims} <- Token.verify(token),
         session when not is_nil(session) <- Accounts.get_live_session(claims.session_id),
         user when not is_nil(user) <- Accounts.get_user(claims.didi_id) do
      json(conn, %{
        workspaces: Workspaces.for_user(user.didi_id),
        joinable: joinable_for(user)
      })
    else
      _ -> conn |> put_status(401) |> json(%{error: "unauthenticated"})
    end
  end

  @doc """
  POST /api/workspaces/:slug/join — self-signup where a domain permits it.

  Refused unless one of the caller's addresses matches the workspace's
  `default_domain`. On success it writes an ordinary membership row; there is no
  second class of member.
  """
  def join(conn, %{"slug" => slug}) do
    with token when is_binary(token) <- SessionCookie.read(conn),
         {:ok, claims} <- Token.verify(token),
         session when not is_nil(session) <- Accounts.get_live_session(claims.session_id),
         user when not is_nil(user) <- Accounts.get_user(claims.didi_id) do
      case Workspaces.auto_join(user.didi_id, slug) do
        {:ok, _} ->
          {:ok, role} = Workspaces.role_of(user.didi_id, slug)
          json(conn, %{slug: slug, role: role, via: "auto_join"})

        {:error, reason} ->
          conn |> put_status(403) |> json(%{error: to_string(reason)})
      end
    else
      _ -> conn |> put_status(401) |> json(%{error: "unauthenticated"})
    end
  end

  # Only surfaced for workspaces the caller is not already in — an offer to
  # someone outside, never a restatement of access they already hold.
  defp joinable_for(user) do
    held = user.didi_id |> Workspaces.for_user() |> MapSet.new(& &1.slug)

    [user.primary_email | Accounts.list_email_aliases(user.didi_id)]
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&Workspaces.joinable_by_email/1)
    |> Enum.reject(&MapSet.member?(held, &1.slug))
    |> Enum.uniq_by(& &1.slug)
  end
end
