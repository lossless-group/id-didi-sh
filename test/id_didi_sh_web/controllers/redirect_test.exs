defmodule IdDidiShWeb.RedirectTest do
  @moduledoc """
  Where a person lands after signing in.

  A post-sign-in destination enters the service three ways: `next` on
  `POST /api/magic-links`, `return_to` on the hosted `/auth` page (the OAuth
  sign-in hop), and whatever an older login token already has stored. It
  leaves two ways: a 302 from `POST /access`, and the `next` field of
  `POST /api/magic-links/redeem`, which the consumer app navigates to.

  The rule (one validator, `IdDidiSh.RedirectTarget`): only a same-site path,
  a single leading `/` followed by something other than `/` or `\\`, with no
  scheme, no host, and no control characters. Anything else falls back to the
  default destination: the "Signed in" page on `/access`, `nil` in the API.

  Spec IDs REDIRECT-01..07.
  """
  use IdDidiShWeb.ConnCase, async: false

  alias IdDidiSh.{Accounts, Repo, RedirectTarget}
  alias IdDidiSh.Accounts.LoginToken

  # Every value here must never become a place a person is sent.
  @hostile [
    "//evil.example",
    "//evil.example/account",
    "///evil.example",
    "/\\evil.example",
    "/\\/evil.example",
    "\\\\evil.example",
    "https://evil.example",
    "http://evil.example/account",
    "https:evil.example",
    "javascript:alert(1)",
    "%2F%2Fevil.example",
    "/%2F%2Fevil.example",
    "/%2Fevil.example",
    "/%5Cevil.example",
    "/%09/evil.example",
    "/\t/evil.example",
    "/\n/evil.example",
    "/\r\n/evil.example",
    "\t//evil.example",
    " //evil.example",
    "/ /evil.example",
    "/\0/evil.example",
    "/account\r\nSet-Cookie: x=y",
    "/account%0d%0aSet-Cookie:%20x=y",
    "evil.example",
    "",
    "   "
  ]

  # Absolute URLs on our own domain used to be accepted on /access. Under the
  # single rule they are not: a destination is a path, never a host.
  @own_domain_absolute ["https://decks.didi.sh/account", "https://didi.sh/"]

  defp seed_user(email) do
    {:ok, user} = Accounts.create_user(%{primary_email: email, name: "Redirect"})
    user
  end

  defp raw_from_email do
    receive do
      {:email, email} ->
        [_, raw] = Regex.run(~r{/access\?token=([A-Za-z0-9_\-]+)}, email.text_body)
        raw
    after
      1000 -> flunk("no magic-link email was sent")
    end
  end

  defp stored_next(raw) do
    hash = :crypto.hash(:sha256, raw)

    case Repo.get_by(LoginToken, token_hash: hash) do
      nil -> flunk("no login token stored for the issued link")
      token -> token.next_path
    end
  end

  # The person must not be sent anywhere: no Location header at all, and the
  # ordinary signed-in page renders.
  defp assert_stays_on_signed_in_page(conn, value) do
    assert conn.status == 200,
           "#{inspect(value)} produced status #{conn.status}, location #{inspect(get_resp_header(conn, "location"))}"

    assert get_resp_header(conn, "location") == []
    assert conn.resp_body =~ "Signed in"
    assert is_binary(conn.resp_cookies["didi_session"][:value])
  end

  # ── REDIRECT-01 ───────────────────────────────────────────────────────────

  describe "the validator" do
    @tag spec: "REDIRECT-01"
    test "rejects every hostile or empty value" do
      for value <- @hostile ++ @own_domain_absolute do
        assert RedirectTarget.sanitize(value) == nil, "accepted #{inspect(value)}"
      end
    end

    @tag spec: "REDIRECT-01"
    test "rejects non-strings" do
      for value <- [nil, 42, ["/account"], %{"path" => "/account"}, :account] do
        assert RedirectTarget.sanitize(value) == nil
      end
    end

    @tag spec: "REDIRECT-01"
    test "keeps legitimate same-site paths unchanged" do
      for value <- [
            "/",
            "/account",
            "/curator",
            "/account/keys?tab=new#top",
            "/oauth/authorize?client_id=abc&redirect_uri=https%3A%2F%2Fclaude.ai%2Fcb&state=x"
          ] do
        assert RedirectTarget.sanitize(value) == value
      end
    end
  end

  # ── REDIRECT-02 ───────────────────────────────────────────────────────────

  describe "/access with a stored destination" do
    @tag spec: "REDIRECT-02"
    test "never redirects to a hostile destination already stored on a token" do
      # A token issued before the fix (or by any path that skipped the check)
      # carries the value as-is. Redemption must still refuse it.
      user = seed_user("stored@example.com")

      for value <- @hostile ++ @own_domain_absolute do
        {:ok, raw, _} = Accounts.issue_magic_link(user.primary_email, next_path: value)
        # Bypass any issue-time cleaning: put the raw value back on the row.
        hash = :crypto.hash(:sha256, raw)

        Repo.get_by!(LoginToken, token_hash: hash)
        |> Ecto.Changeset.change(next_path: value)
        |> Repo.update!()

        conn = post(build_conn(), ~p"/access", %{"token" => raw})
        assert_stays_on_signed_in_page(conn, value)
      end
    end

    @tag spec: "REDIRECT-03"
    test "still sends a person to a legitimate same-site path" do
      user = seed_user("legit@example.com")
      {:ok, raw, _} = Accounts.issue_magic_link(user.primary_email, next_path: "/account")

      conn = post(build_conn(), ~p"/access", %{"token" => raw})
      assert redirected_to(conn, 302) == "/account"
      assert is_binary(conn.resp_cookies["didi_session"][:value])
    end

    @tag spec: "REDIRECT-03"
    test "with no destination at all, renders the signed-in page" do
      user = seed_user("plain@example.com")
      {:ok, raw, _} = Accounts.issue_magic_link(user.primary_email)

      conn = post(build_conn(), ~p"/access", %{"token" => raw})
      assert_stays_on_signed_in_page(conn, nil)
    end
  end

  # ── REDIRECT-04 ───────────────────────────────────────────────────────────

  describe "POST /api/magic-links with a hostile next" do
    @tag spec: "REDIRECT-04"
    test "is not stored, not echoed by the API redeem, and not followed by /access" do
      user = seed_user("api@example.com")

      for value <- @hostile ++ @own_domain_absolute do
        # API redeem path
        conn =
          post(build_conn(), ~p"/api/magic-links", %{
            "email" => user.primary_email,
            "app" => "test",
            "next" => value
          })

        assert conn.status == 202
        raw = raw_from_email()
        assert stored_next(raw) == nil, "stored #{inspect(value)}"

        conn = post(build_conn(), ~p"/api/magic-links/redeem", %{"token" => raw})
        body = json_response(conn, 200)
        assert body["didi_id"] == user.didi_id
        assert body["next"] == nil, "API redeem echoed #{inspect(value)}"

        # /access redeem path, from a fresh API-issued link
        conn =
          post(build_conn(), ~p"/api/magic-links", %{
            "email" => user.primary_email,
            "next" => value
          })

        assert conn.status == 202
        raw = raw_from_email()
        conn = post(build_conn(), ~p"/access", %{"token" => raw})
        assert_stays_on_signed_in_page(conn, value)
      end
    end

    @tag spec: "REDIRECT-04"
    test "a non-string next is ignored rather than crashing the issue" do
      user = seed_user("shape@example.com")

      for value <- [["//evil.example"], %{"to" => "//evil.example"}, 42] do
        conn =
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> post(
            ~p"/api/magic-links",
            Jason.encode!(%{"email" => user.primary_email, "next" => value})
          )

        assert conn.status == 202
        assert stored_next(raw_from_email()) == nil
      end
    end
  end

  # ── REDIRECT-05 ───────────────────────────────────────────────────────────

  describe "POST /api/magic-links with a legitimate next" do
    @tag spec: "REDIRECT-05"
    test "carries /account through both redeem paths" do
      user = seed_user("api-legit@example.com")

      post(build_conn(), ~p"/api/magic-links", %{
        "email" => user.primary_email,
        "next" => "/account"
      })

      raw = raw_from_email()
      assert stored_next(raw) == "/account"
      conn = post(build_conn(), ~p"/api/magic-links/redeem", %{"token" => raw})
      assert json_response(conn, 200)["next"] == "/account"

      post(build_conn(), ~p"/api/magic-links", %{
        "email" => user.primary_email,
        "next" => "/account"
      })

      conn = post(build_conn(), ~p"/access", %{"token" => raw_from_email()})
      assert redirected_to(conn, 302) == "/account"
    end
  end

  # ── REDIRECT-06 ───────────────────────────────────────────────────────────

  describe "invites" do
    @tag spec: "REDIRECT-06"
    test "an invite carrying a hostile destination signs in without redirecting" do
      for {value, i} <- Enum.with_index(@hostile) do
        email = "invitee#{i}@example.com"
        {:ok, raw, _} = Accounts.issue_invite(email, next_path: value)
        assert stored_next(raw) == nil, "invite stored #{inspect(value)}"

        conn = post(build_conn(), ~p"/access", %{"token" => raw})
        assert_stays_on_signed_in_page(conn, value)
      end
    end
  end

  # ── REDIRECT-07 ───────────────────────────────────────────────────────────

  describe "the OAuth sign-in hop (/auth?return_to=)" do
    @tag spec: "REDIRECT-07"
    test "applies the same rule on top of the authorize-only prefix" do
      user = seed_user("hop@example.com")

      for value <- [
            "/oauth/authorize?x=1\r\nSet-Cookie: x=y",
            "/oauth/authorize?\t//evil.example",
            "/oauth/authorize?\\evil.example",
            "/oauth/authorize?x=\0"
          ] do
        page = build_conn() |> get("/auth", %{"return_to" => value}) |> html_response(200)
        refute page =~ ~s(name="return_to"), "form kept #{inspect(value)}"

        post(build_conn(), "/auth", %{"email" => user.primary_email, "return_to" => value})
        raw = raw_from_email()
        assert stored_next(raw) == nil, "/auth stored #{inspect(value)}"

        conn = post(build_conn(), ~p"/access", %{"token" => raw})
        assert_stays_on_signed_in_page(conn, value)
      end
    end

    @tag spec: "REDIRECT-07"
    test "a legitimate authorize way back still survives the hop" do
      user = seed_user("hop-legit@example.com")
      value = "/oauth/authorize?client_id=abc&state=xyz"

      page = build_conn() |> get("/auth", %{"return_to" => value}) |> html_response(200)
      assert page =~ ~s(name="return_to")

      post(build_conn(), "/auth", %{"email" => user.primary_email, "return_to" => value})
      raw = raw_from_email()
      assert stored_next(raw) == value

      conn = post(build_conn(), ~p"/access", %{"token" => raw})
      assert redirected_to(conn, 302) == value
    end
  end
end
