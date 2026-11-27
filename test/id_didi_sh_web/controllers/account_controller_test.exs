defmodule IdDidiShWeb.AccountControllerTest do
  @moduledoc """
  `/account` — the browser surface over the same context functions the JSON
  API uses. Pinned here: a signed-out person is sent to sign in on every
  action, the page shows entities and the labelled legacy block, and adding a
  member is gated on admin and invites an unknown address rather than
  refusing it.
  """
  use IdDidiShWeb.ConnCase, async: false

  import Swoosh.TestAssertions

  alias IdDidiSh.{Accounts, Entities, Repo, Token}
  alias IdDidiSh.Accounts.LoginToken

  defp signed_in(email \\ "owner-#{System.unique_integer([:positive])}@firm.test") do
    {:ok, user} = Accounts.create_user(%{primary_email: email, name: "Owner"})
    session = Accounts.create_session(user)
    cookie = Token.sign(user.didi_id, session.id)
    {user, build_conn() |> put_req_cookie("didi_session", cookie)}
  end

  defp entity!(slug, didi_id, role) do
    {:ok, e} = Entities.create_entity(%{"kind" => "project", "slug" => slug, "name" => slug})
    {:ok, _} = Entities.add_member(e.id, didi_id, role, via: "seed")
    e
  end

  defp flash(conn, key), do: Phoenix.Flash.get(conn.assigns.flash, key)

  describe "signed out" do
    test "every action sends the person to sign in" do
      requests = [
        {:get, "/account", %{}},
        {:post, "/account/profile", %{"name" => "x"}},
        {:post, "/account/emails", %{"email" => "x@y.z"}},
        {:post, "/account/entities", %{"kind" => "project", "slug" => "s", "name" => "n"}},
        {:post, "/account/entities/abc/members", %{"email" => "x@y.z"}}
      ]

      for {method, path, params} <- requests do
        conn = dispatch(build_conn(), @endpoint, method, path, params)
        assert redirected_to(conn) == "/auth", "#{method} #{path} did not redirect"
      end
    end

    test "a cookie for a revoked session is treated as signed out" do
      {:ok, user} = Accounts.create_user(%{primary_email: "gone@firm.test"})
      session = Accounts.create_session(user)
      cookie = Token.sign(user.didi_id, session.id)
      Accounts.revoke_session(session.id)

      conn = build_conn() |> put_req_cookie("didi_session", cookie) |> get("/account")
      assert redirected_to(conn) == "/auth"
    end
  end

  describe "show" do
    test "lists entities with role, and labels legacy orgs separately" do
      {user, conn} = signed_in()
      entity!("apollo", user.didi_id, "editor")
      {:ok, _} = Accounts.upsert_org("legacy.test", "Legacy Co")
      {:ok, _} = Accounts.upsert_membership(user.didi_id, "legacy.test", "viewer")
      {:ok, _} = Accounts.add_email_alias(user, "alt@elsewhere.test")

      page = conn |> get("/account") |> html_response(200)

      assert page =~ user.primary_email
      assert page =~ "apollo"
      assert page =~ "editor"
      assert page =~ "Organizations (legacy)"
      assert page =~ "Legacy Co"
      assert page =~ "alt@elsewhere.test"
    end

    test "omits the legacy block when there are no legacy orgs" do
      {_user, conn} = signed_in()
      refute conn |> get("/account") |> html_response(200) =~ "Organizations (legacy)"
    end

    test "a membership whose entity is gone still renders, not hidden" do
      {user, conn} = signed_in()
      orphan_id = "01a00000-0000-7000-8000-00000000dead"

      # The FK cascade makes this state hard to reach, which is exactly why the
      # page must not hide it when it happens (a restore, a hand edit). Defer
      # the FK check to a commit the sandbox never performs.
      Repo.query!("PRAGMA defer_foreign_keys = ON")

      Repo.query!(
        """
        INSERT INTO entity_memberships (didi_id, entity_id, role, via, inserted_at, updated_at)
        VALUES (?, ?, 'viewer', 'seed', datetime('now'), datetime('now'))
        """,
        [user.didi_id, orphan_id]
      )

      assert conn |> get("/account") |> html_response(200) =~ orphan_id
    end
  end

  describe "profile and aliases" do
    test "saving a profile updates the name" do
      {user, conn} = signed_in()
      conn = post(conn, "/account/profile", %{"name" => "New Name"})

      assert redirected_to(conn) == "/account"
      assert flash(conn, :info) == "Profile saved."
      assert Accounts.get_user(user.didi_id).name == "New Name"
    end

    test "linking an alias: good, malformed, and already taken" do
      {user, conn} = signed_in()
      {:ok, _other} = Accounts.create_user(%{primary_email: "taken@firm.test"})

      ok = post(conn, "/account/emails", %{"email" => "me@alt.test"})
      assert flash(ok, :info) == "me@alt.test linked to your account."
      assert "me@alt.test" in Accounts.list_email_aliases(user.didi_id)

      bad = post(conn, "/account/emails", %{"email" => "nope"})
      assert flash(bad, :error) == "That does not look like an email address."

      taken = post(conn, "/account/emails", %{"email" => "taken@firm.test"})
      assert flash(taken, :error) =~ "Could not link that address"
      refute "taken@firm.test" in Accounts.list_email_aliases(user.didi_id)
    end
  end

  describe "creating an entity" do
    test "the creator becomes its admin" do
      {user, conn} = signed_in()

      conn =
        post(conn, "/account/entities", %{"kind" => "project", "slug" => " q4 ", "name" => "Q4"})

      assert flash(conn, :info) == "Q4 created — you are its admin."
      entity = Entities.get_entity_by_slug("q4")
      assert Entities.effective_role(entity.id, user.didi_id) == "org_admin"
    end

    test "a taken handle and an invalid kind are refused with a reason" do
      {user, conn} = signed_in()
      entity!("apollo", user.didi_id, "viewer")

      taken =
        post(conn, "/account/entities", %{"kind" => "project", "slug" => "apollo", "name" => "A"})

      assert flash(taken, :error) == "That handle is already taken."

      bad = post(conn, "/account/entities", %{"kind" => "squad", "slug" => "s", "name" => "S"})
      assert flash(bad, :error) =~ "Could not create that entity"
    end
  end

  describe "adding a member" do
    test "a non-admin is refused and nothing is granted" do
      {user, conn} = signed_in()
      e = entity!("apollo", user.didi_id, "editor")
      {:ok, target} = Accounts.create_user(%{primary_email: "target@firm.test"})

      conn = post(conn, "/account/entities/#{e.id}/members", %{"email" => "target@firm.test"})

      assert flash(conn, :error) == "You need admin on that entity to add anyone to it."
      assert Entities.effective_role(e.id, target.didi_id) == nil
    end

    test "an empty email is refused" do
      {user, conn} = signed_in()
      e = entity!("apollo", user.didi_id, "org_admin")

      conn = post(conn, "/account/entities/#{e.id}/members", %{"email" => "  "})
      assert flash(conn, :error) == "Enter an email address."
    end

    test "a known address is added directly, case-insensitively, with the given role" do
      {user, conn} = signed_in()
      e = entity!("apollo", user.didi_id, "org_owner")
      {:ok, target} = Accounts.create_user(%{primary_email: "target@firm.test"})

      conn =
        post(conn, "/account/entities/#{e.id}/members", %{
          "email" => " Target@Firm.test ",
          "role" => "editor"
        })

      assert flash(conn, :info) == "target@firm.test added as editor."
      assert Entities.effective_role(e.id, target.didi_id) == "editor"
      assert_no_email_sent()
    end

    test "a known address with an invalid role is refused with a reason" do
      {user, conn} = signed_in()
      e = entity!("apollo", user.didi_id, "org_admin")
      {:ok, _} = Accounts.create_user(%{primary_email: "target@firm.test"})

      conn =
        post(conn, "/account/entities/#{e.id}/members", %{
          "email" => "target@firm.test",
          "role" => "emperor"
        })

      assert flash(conn, :error) =~ "Could not add them"
    end

    test "an unknown address is invited, defaulting to viewer, and the invite is mailed" do
      {user, conn} = signed_in()
      e = entity!("apollo", user.didi_id, "org_admin")

      conn = post(conn, "/account/entities/#{e.id}/members", %{"email" => "new@firm.test"})

      assert flash(conn, :info) == "Invited new@firm.test as viewer."

      invite = Repo.get_by!(LoginToken, kind: "invite", email: "new@firm.test")
      assert invite.entity_id == e.id
      assert invite.role == "viewer"
      assert invite.issued_by == user.didi_id

      assert_email_sent(to: [{"", "new@firm.test"}])
    end
  end
end
