defmodule IdDidiShWeb.KeysLiveTest do
  use IdDidiShWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias IdDidiSh.{Accounts, Credentials, Entities}

  @secret "sk-ant-liveview-8888"

  defp user(email) do
    {:ok, u} = Accounts.create_user(%{primary_email: email, name: "Alice"})
    u
  end

  defp signed_in_conn(u) do
    {:ok, raw, _} = Accounts.issue_magic_link(u.primary_email)
    c = post(build_conn(), ~p"/api/magic-links/redeem", %{"token" => raw})
    build_conn() |> put_req_cookie("didi_session", c.resp_cookies["didi_session"][:value])
  end

  defp entity(slug) do
    {:ok, e} = Entities.create_entity(%{kind: "project", slug: slug, name: String.upcase(slug)})
    e
  end

  describe "access" do
    test "a signed-out visitor is sent to sign in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/access"}}} = live(conn, ~p"/keys")
    end
  end

  describe "THE GATE — a human pastes a key and lends it, no terminal" do
    test "paste, pick two places, lend" do
      alice = user("alice@example.com")
      a = entity("apollo")
      b = entity("boreas")
      {:ok, _} = Entities.add_member(a.id, alice.didi_id, "org_owner")
      {:ok, _} = Entities.add_member(b.id, alice.didi_id, "org_owner")

      {:ok, view, _html} = live(signed_in_conn(alice), ~p"/keys")

      view
      |> form(~s{form[phx-submit="paste"]}, %{
        "provider" => "anthropic",
        "label" => "Jason's card",
        "value" => @secret
      })
      |> render_submit()

      [cred] = Credentials.list_credentials(alice.didi_id)
      assert cred.label == "Jason's card"

      html =
        view
        |> element(~s{button[phx-click="start_lending"][phx-value-id="#{cred.id}"]})
        |> render_click()

      assert html =~ "Lend to which?"

      view |> element(~s{input[phx-value-id="#{a.id}"]}) |> render_click()
      html = view |> element(~s{input[phx-value-id="#{b.id}"]}) |> render_click()

      # Ruling 2b: the consequence is visible BEFORE confirming.
      assert html =~ "including anyone added later"

      view |> element(~s{button[phx-click="lend"]}) |> render_click()

      # Admin in both, by lending, with no extra membership needed.
      assert Entities.effective_role(a.id, alice.didi_id) == :admin
      assert Entities.effective_role(b.id, alice.didi_id) == :admin
    end
  end

  describe "the value is write-only" do
    test "it never appears in the rendered page, only the last four" do
      alice = user("alice@example.com")
      {:ok, _} = Credentials.create_credential(alice.didi_id, "anthropic", "card", @secret)

      {:ok, _view, html} = live(signed_in_conn(alice), ~p"/keys")

      refute html =~ @secret
      assert html =~ "8888"
    end
  end

  describe "taking it back" do
    test "revoking shows as revoked and ends lending" do
      alice = user("alice@example.com")
      a = entity("apollo")
      {:ok, cred} = Credentials.create_credential(alice.didi_id, "anthropic", "card", @secret)
      {:ok, _, _} = Credentials.lend(cred.id, [a.id], %{}, alice.didi_id)

      {:ok, view, _} = live(signed_in_conn(alice), ~p"/keys")

      html =
        view
        |> element(~s{button[phx-click="revoke"][phx-value-id="#{cred.id}"]})
        |> render_click()

      assert html =~ "revoked"
      assert Entities.effective_role(a.id, alice.didi_id) == nil
    end
  end

  describe "errors speak English" do
    test "pasting an empty value explains, rather than showing an atom" do
      alice = user("alice@example.com")
      {:ok, view, _} = live(signed_in_conn(alice), ~p"/keys")

      html =
        view
        |> form(~s{form[phx-submit="paste"]}, %{
          "provider" => "anthropic",
          "label" => "x",
          "value" => ""
        })
        |> render_submit()

      assert html =~ "Paste the key before storing it"
      refute html =~ "empty_value"
    end
  end
end
