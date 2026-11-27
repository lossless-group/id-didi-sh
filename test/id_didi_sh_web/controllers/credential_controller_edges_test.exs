defmodule IdDidiShWeb.CredentialControllerEdgesTest do
  @moduledoc """
  The refusals of the credentials API and the lending terms. The value gate
  and the happy paths live in `credential_controller_test.exs`.
  """
  use IdDidiShWeb.ConnCase, async: false

  alias IdDidiSh.{Accounts, Entities}

  @nowhere "01a00000-0000-7000-8000-00000000beef"

  defp user(email) do
    {:ok, u} = Accounts.create_user(%{primary_email: email, name: email})
    u
  end

  defp as(u) do
    {:ok, raw, _} = Accounts.issue_magic_link(u.primary_email)
    c = post(build_conn(), ~p"/api/magic-links/redeem", %{"token" => raw})
    build_conn() |> put_req_cookie("didi_session", c.resp_cookies["didi_session"][:value])
  end

  defp entity(slug) do
    {:ok, e} = Entities.create_entity(%{kind: "project", slug: slug, name: String.upcase(slug)})
    e
  end

  defp paste(u) do
    post(as(u), ~p"/api/credentials", %{
      "provider" => "anthropic",
      "label" => "card",
      "value" => "sk-ant-edge-1234"
    })
    |> json_response(201)
    |> Map.fetch!("credential")
  end

  defp lend(u, cred_id, body) do
    post(as(u), ~p"/api/credentials/#{cred_id}/cascades", body)
  end

  test "creating a credential with no value is 422" do
    alice = user("alice@example.com")

    conn = post(as(alice), ~p"/api/credentials", %{"provider" => "anthropic", "label" => "x"})
    assert %{"error" => _} = json_response(conn, 422)
  end

  test "revoking an unknown credential is 404" do
    alice = user("alice@example.com")

    assert json_response(delete(as(alice), ~p"/api/credentials/#{@nowhere}"), 404)["error"] ==
             "not_found"
  end

  test "usage of an unknown credential is 404" do
    alice = user("alice@example.com")

    assert json_response(get(as(alice), ~p"/api/credentials/#{@nowhere}/usage"), 404)["error"] ==
             "not_found"
  end

  describe "lending terms" do
    test "a cap, a period, and an ISO expiry are recorded on the cascade" do
      alice = user("alice@example.com")
      cred = paste(alice)
      apollo = entity("apollo")

      body =
        lend(alice, cred["id"], %{
          "entity_ids" => [apollo.id],
          "spend_cap" => 500,
          "cap_period" => "month",
          "expires_at" => "2027-01-01T00:00:00.123Z"
        })
        |> json_response(201)

      assert body["cascade"]["spend_cap"] == 500
      assert body["cascade"]["cap_period"] == "month"
      assert body["cascade"]["expires_at"] == "2027-01-01T00:00:00Z"
      assert body["notice"] =~ "1 entity,"
    end

    test "an unparseable expiry is ignored rather than guessed at" do
      alice = user("alice@example.com")
      cred = paste(alice)
      apollo = entity("apollo")

      body =
        lend(alice, cred["id"], %{"entity_ids" => [apollo.id], "expires_at" => "next tuesday"})
        |> json_response(201)

      assert body["cascade"]["expires_at"] == nil
    end

    test "bad terms and bad targets are 422 with the reason" do
      alice = user("alice@example.com")
      cred = paste(alice)
      apollo = entity("apollo")

      assert json_response(lend(alice, cred["id"], %{"entity_ids" => []}), 422)["error"] ==
               "no_entities"

      assert json_response(lend(alice, cred["id"], %{"entity_ids" => [@nowhere]}), 422)["error"] ==
               "unknown_entity"

      assert json_response(
               lend(alice, cred["id"], %{"entity_ids" => [apollo.id], "cap_period" => "year"}),
               422
             )["error"] == "invalid_cap_period"

      assert json_response(lend(alice, @nowhere, %{"entity_ids" => [apollo.id]}), 422)["error"] ==
               "unknown_credential"
    end
  end

  describe "ending loans and cascades" do
    setup do
      alice = user("alice@example.com")
      bob = user("bob@example.com")
      cred = paste(alice)
      apollo = entity("apollo")

      cascade =
        lend(alice, cred["id"], %{"entity_ids" => [apollo.id]})
        |> json_response(201)
        |> Map.fetch!("cascade")

      %{alice: alice, bob: bob, apollo: apollo, cascade: cascade}
    end

    test "only the lender can end a cascade", %{bob: bob, cascade: c} do
      conn = delete(as(bob), ~p"/api/cascades/#{c["id"]}")
      assert json_response(conn, 403)["error"] == "not_the_lender"
    end

    test "ending an unknown cascade is 404", %{alice: alice} do
      assert json_response(delete(as(alice), ~p"/api/cascades/#{@nowhere}"), 404)["error"] ==
               "not_found"
    end

    test "end_loan refuses an unknown cascade, a non-lender, and a loan already ended", ctx do
      %{alice: alice, bob: bob, apollo: apollo, cascade: c} = ctx

      assert json_response(
               delete(as(alice), ~p"/api/cascades/#{@nowhere}/loans/#{apollo.id}"),
               404
             )[
               "error"
             ] == "not_found"

      assert json_response(delete(as(bob), ~p"/api/cascades/#{c["id"]}/loans/#{apollo.id}"), 403)[
               "error"
             ] == "not_the_lender"

      assert json_response(
               delete(as(alice), ~p"/api/cascades/#{c["id"]}/loans/#{apollo.id}"),
               200
             )

      assert json_response(
               delete(as(alice), ~p"/api/cascades/#{c["id"]}/loans/#{apollo.id}"),
               404
             )[
               "error"
             ] == "no_live_loan"
    end
  end
end
