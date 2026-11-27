defmodule IdDidiShWeb.AuthControllerTest do
  @moduledoc """
  The hosted sign-in page, `GET/POST /auth`. Redirect sanitising is pinned in
  `redirect_test.exs`; this file pins input handling and the rule that the
  page never reveals whether an account exists.
  """
  use IdDidiShWeb.ConnCase, async: true

  import Swoosh.TestAssertions

  alias IdDidiSh.Accounts

  test "GET renders the sign-in form", %{conn: conn} do
    assert html_response(get(conn, "/auth"), 200) =~ "Sign in to didi.sh"
  end

  test "input that is not an email re-renders the form with an error", %{conn: conn} do
    for bad <- ["", "   ", "not-an-address"] do
      page = conn |> post("/auth", %{"email" => bad}) |> html_response(200)
      assert page =~ "That does not look like an email address."
    end

    assert_no_email_sent()
  end

  test "a submission without an email field re-renders with a prompt", %{conn: conn} do
    page = conn |> post("/auth", %{}) |> html_response(200)
    assert page =~ "Enter the email you were invited with."
  end

  test "a known and an unknown address get the identical page (no enumeration oracle)" do
    {:ok, user} = Accounts.create_user(%{primary_email: "known@firm.test", name: "Known"})

    known =
      build_conn() |> post("/auth", %{"email" => user.primary_email}) |> html_response(200)

    unknown =
      build_conn() |> post("/auth", %{"email" => "stranger@firm.test"}) |> html_response(200)

    assert known =~ "Check your email"

    # The CSRF token is per-request by design; everything else must match.
    normalize = fn page, email ->
      page
      |> String.replace(email, "X")
      |> String.replace(~r/name="csrf-token" content="[^"]+"/, "csrf")
    end

    assert normalize.(known, user.primary_email) == normalize.(unknown, "stranger@firm.test")

    # Only the known address actually gets mail.
    assert_email_sent(to: [{"", user.primary_email}])
    refute_email_sent()
  end

  test "surrounding whitespace is trimmed before the link is issued" do
    {:ok, user} = Accounts.create_user(%{primary_email: "trim@firm.test", name: "Trim"})

    build_conn() |> post("/auth", %{"email" => "  trim@firm.test  "}) |> html_response(200)

    assert_email_sent(to: [{"", user.primary_email}])
  end
end
