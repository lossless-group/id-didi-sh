defmodule IdDidiShWeb.WorkspaceControllerTest do
  @moduledoc """
  The workspaces endpoints, over a real session.

  The behaviour worth protecting here is the separation of two lists.
  `workspaces` is access, held by grant. `joinable` is an *offer*, extended on
  the strength of an email domain. Collapsing them would rebuild the
  domain-derived model the 2026-08-09 amendment removed — so the test that
  matters most is the one asserting a matching domain puts a workspace in
  `joinable` and NOT in `workspaces`.
  """

  use IdDidiShWeb.ConnCase, async: false

  alias IdDidiSh.Accounts
  alias IdDidiSh.Workspaces

  defp seed_user(email) do
    {:ok, user} = Accounts.create_user(%{primary_email: email, name: email})
    user
  end

  defp session_for(user) do
    {:ok, raw, _} = Accounts.issue_magic_link(user.primary_email)
    conn = post(build_conn(), ~p"/api/magic-links/redeem", %{"token" => raw})
    conn.resp_cookies["didi_session"][:value]
  end

  defp as(user), do: build_conn() |> put_req_cookie("didi_session", session_for(user))

  describe "GET /api/workspaces" do
    test "401 without a session", %{conn: conn} do
      assert json_response(get(conn, ~p"/api/workspaces"), 401)
    end

    test "lists granted workspaces regardless of the caller's email domain" do
      # The operator's real shape: three clients, one login, none of the
      # addresses matching.
      operator = seed_user("michael@humain.vc")

      {:ok, _} =
        Workspaces.upsert_workspace("reach-edu", "Reach Edu", default_domain: "reach.edu")

      {:ok, _} =
        Workspaces.upsert_workspace("palmer-ai", "Palmer AI", default_domain: "palmer.ai")

      for slug <- ~w(reach-edu palmer-ai) do
        {:ok, _} = Workspaces.grant(operator.didi_id, slug, "org_admin")
      end

      body = json_response(get(as(operator), ~p"/api/workspaces"), 200)

      assert Enum.map(body["workspaces"], & &1["slug"]) == ~w(palmer-ai reach-edu)
      assert Enum.all?(body["workspaces"], &(&1["role"] == "org_admin"))
    end

    test "a matching domain lands in joinable, NOT in workspaces" do
      # The sharp edge. Sharing a domain is an offer to ask, not access.
      stranger = seed_user("newhire@reach.edu")

      {:ok, _} =
        Workspaces.upsert_workspace("reach-edu", "Reach Edu", default_domain: "reach.edu")

      body = json_response(get(as(stranger), ~p"/api/workspaces"), 200)

      assert body["workspaces"] == []
      assert [%{"slug" => "reach-edu"}] = body["joinable"]
    end

    test "an advisor sees their grant and no offers" do
      advisor = seed_user("advisor@some-vc-fund.com")

      {:ok, _} =
        Workspaces.upsert_workspace("reach-edu", "Reach Edu", default_domain: "reach.edu")

      {:ok, _} = Workspaces.grant(advisor.didi_id, "reach-edu", "viewer")

      body = json_response(get(as(advisor), ~p"/api/workspaces"), 200)

      assert [%{"slug" => "reach-edu", "role" => "viewer"}] = body["workspaces"]
      assert body["joinable"] == []
    end

    test "a workspace already held is never re-offered as joinable" do
      member = seed_user("staff@reach.edu")

      {:ok, _} =
        Workspaces.upsert_workspace("reach-edu", "Reach Edu", default_domain: "reach.edu")

      {:ok, _} = Workspaces.grant(member.didi_id, "reach-edu", "editor")

      body = json_response(get(as(member), ~p"/api/workspaces"), 200)

      assert [%{"slug" => "reach-edu"}] = body["workspaces"]
      assert body["joinable"] == []
    end
  end

  describe "POST /api/workspaces/:slug/join" do
    test "401 without a session", %{conn: conn} do
      assert json_response(post(conn, ~p"/api/workspaces/reach-edu/join"), 401)
    end

    test "a matching domain may self-join, and gets an ordinary membership" do
      newhire = seed_user("newhire@reach.edu")

      {:ok, _} =
        Workspaces.upsert_workspace("reach-edu", "Reach Edu", default_domain: "reach.edu")

      body = json_response(post(as(newhire), ~p"/api/workspaces/reach-edu/join"), 200)

      assert body["role"] == "viewer"
      assert body["via"] == "auto_join"
      assert Workspaces.member?(newhire.didi_id, "reach-edu")
    end

    test "a mismatched domain is refused" do
      # An account exists; the workspace is still not theirs to enter.
      advisor = seed_user("advisor@some-vc-fund.com")

      {:ok, _} =
        Workspaces.upsert_workspace("reach-edu", "Reach Edu", default_domain: "reach.edu")

      body = json_response(post(as(advisor), ~p"/api/workspaces/reach-edu/join"), 403)

      assert body["error"] == "domain_mismatch"
      refute Workspaces.member?(advisor.didi_id, "reach-edu")
    end

    test "a workspace with no default domain cannot be joined at all" do
      someone = seed_user("someone@anywhere.com")
      {:ok, _} = Workspaces.upsert_workspace("private-thing", "Private Thing")

      body = json_response(post(as(someone), ~p"/api/workspaces/private-thing/join"), 403)

      assert body["error"] == "no_default_domain"
    end

    test "joining does NOT create an account — the invite-only invariant holds" do
      # This endpoint grants MEMBERSHIP to someone who already authenticated. It
      # is not a signup path: no session, no join, and no user is ever minted
      # here. Per this repo's CLAUDE.md, invite redemption remains the sole
      # account-creation route.
      {:ok, _} =
        Workspaces.upsert_workspace("reach-edu", "Reach Edu", default_domain: "reach.edu")

      before = Accounts.count_users()

      assert json_response(post(build_conn(), ~p"/api/workspaces/reach-edu/join"), 401)

      assert Accounts.count_users() == before
    end
  end
end
