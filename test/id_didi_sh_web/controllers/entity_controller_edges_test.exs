defmodule IdDidiShWeb.EntityControllerEdgesTest do
  @moduledoc """
  The refusals of the entities API — unknown ids, non-members, bad input —
  and `GET /api/entities/:id/members`, which nothing exercised before. The
  happy paths live in `entity_controller_test.exs`.
  """
  use IdDidiShWeb.ConnCase, async: false

  import Swoosh.TestAssertions

  alias IdDidiSh.{Accounts, Entities}

  @nowhere "01a00000-0000-7000-8000-00000000beef"

  defp seed_user(email, name \\ nil) do
    {:ok, user} = Accounts.create_user(%{primary_email: email, name: name})
    user
  end

  defp as(user) do
    {:ok, raw, _} = Accounts.issue_magic_link(user.primary_email)
    conn = post(build_conn(), ~p"/api/magic-links/redeem", %{"token" => raw})
    build_conn() |> put_req_cookie("didi_session", conn.resp_cookies["didi_session"][:value])
  end

  defp entity!(owner, slug) do
    {:ok, e} = Entities.create_entity(%{kind: "project", slug: slug, name: String.upcase(slug)})
    {:ok, _} = Entities.add_member(e.id, owner.didi_id, "org_owner", via: "seed")
    e
  end

  describe "create" do
    test "invalid input is 422 with the reason" do
      alice = seed_user("alice@example.com")

      conn =
        post(as(alice), ~p"/api/entities", %{"kind" => "squad", "slug" => "x", "name" => "X"})

      assert json_response(conn, 422)["error"] == "invalid_kind"

      conn = post(as(alice), ~p"/api/entities", %{"kind" => "project", "name" => "No slug"})
      assert json_response(conn, 422)["error"] == "slug_required"
    end
  end

  describe "unknown entity ids are 404 everywhere" do
    test "show, list_members, add_member, delete_member" do
      alice = seed_user("alice@example.com")
      c = as(alice)

      assert json_response(get(c, ~p"/api/entities/#{@nowhere}"), 404)["error"] ==
               "unknown_entity"

      assert json_response(get(c, ~p"/api/entities/#{@nowhere}/members"), 404)["error"] ==
               "unknown_entity"

      assert json_response(
               post(c, ~p"/api/entities/#{@nowhere}/members", %{"email" => "x@y.z"}),
               404
             )[
               "error"
             ] == "unknown_entity"

      assert json_response(delete(c, ~p"/api/entities/#{@nowhere}/members/#{alice.didi_id}"), 404)[
               "error"
             ] == "unknown_entity"
    end
  end

  describe "list_members" do
    test "a member sees every member with their role" do
      alice = seed_user("alice@example.com", "Alice")
      bob = seed_user("bob@example.com", "Bob")
      e = entity!(alice, "apollo")
      {:ok, _} = Entities.add_member(e.id, bob.didi_id, "viewer", via: "invite")

      members = get(as(bob), ~p"/api/entities/#{e.id}/members") |> json_response(200)

      roles = Map.new(members["members"], &{&1["didi_id"], &1["role"]})
      assert roles == %{alice.didi_id => "org_owner", bob.didi_id => "viewer"}
    end

    test "a non-member cannot see who is in it" do
      alice = seed_user("alice@example.com")
      mallory = seed_user("mallory@example.com")
      e = entity!(alice, "apollo")

      conn = get(as(mallory), ~p"/api/entities/#{e.id}/members")
      assert json_response(conn, 403)["error"] == "not_a_member"
    end
  end

  describe "add_member refusals" do
    test "a non-member is not_a_member; an invalid role is 422" do
      alice = seed_user("alice@example.com")
      mallory = seed_user("mallory@example.com")
      e = entity!(alice, "apollo")

      conn = post(as(mallory), ~p"/api/entities/#{e.id}/members", %{"email" => "x@y.z"})
      assert json_response(conn, 403)["error"] == "not_a_member"

      conn =
        post(as(alice), ~p"/api/entities/#{e.id}/members", %{"email" => "x@y.z", "role" => "god"})

      assert json_response(conn, 422)["error"] == "invalid_role"
      assert_no_email_sent()
    end

    test "a non-member cannot remove anyone" do
      alice = seed_user("alice@example.com")
      mallory = seed_user("mallory@example.com")
      e = entity!(alice, "apollo")

      conn = delete(as(mallory), ~p"/api/entities/#{e.id}/members/#{alice.didi_id}")
      assert json_response(conn, 403)["error"] == "not_a_member"
      assert Entities.effective_role(e.id, alice.didi_id) == "org_owner"
    end
  end

  describe "the removal disclosure" do
    test "names someone with no account by their didi_id rather than inventing a name" do
      alice = seed_user("alice@example.com")
      e = entity!(alice, "apollo")

      body =
        delete(as(alice), ~p"/api/entities/#{e.id}/members/#{@nowhere}") |> json_response(200)

      assert body["disclosure"] == "#{@nowhere} will no longer have access to anything here."
    end
  end
end
