defmodule IdDidiSh.EntitiesTest do
  use IdDidiSh.DataCase, async: false

  alias IdDidiSh.Accounts
  alias IdDidiSh.Entities
  alias IdDidiSh.Entities.Entity

  defp seed_user(email \\ "alice@example.com") do
    {:ok, user} = Accounts.create_user(%{primary_email: email, name: "Alice"})
    user
  end

  defp seed_entity(slug, kind \\ "project") do
    {:ok, entity} = Entities.create_entity(%{kind: kind, slug: slug, name: String.upcase(slug)})
    entity
  end

  describe "create_entity/1" do
    test "creates entities of every kind — they are labels, not levels" do
      for kind <- ~w(organization workspace project) do
        assert {:ok, e} = Entities.create_entity(%{kind: kind, slug: "s-#{kind}", name: kind})
        assert e.kind == kind
        assert e.id =~ ~r/^[0-9a-f]{8}-/
      end
    end

    test "rejects an unknown kind" do
      assert {:error, :invalid_kind} =
               Entities.create_entity(%{kind: "team", slug: "x", name: "X"})
    end

    test "rejects a duplicate slug" do
      seed_entity("apollo")
      assert {:error, :slug_taken} = Entities.create_entity(%{kind: "project", slug: "apollo", name: "Apollo II"})
    end
  end

  describe "the no-hierarchy invariant (Ruling 1)" do
    test "entities have no parent_id" do
      # A schema assertion on purpose: if someone adds containment in a future
      # migration, this fails loudly rather than hierarchy creeping back in.
      refute :parent_id in Entity.__schema__(:fields)
    end
  end

  describe "membership" do
    test "adds a member and reads the role back" do
      user = seed_user()
      entity = seed_entity("apollo")

      assert {:ok, m} = Entities.add_member(entity.id, user.didi_id, "editor", via: "seed")
      assert m.role == "editor"
      assert m.via == "seed"
      assert Entities.effective_role(entity.id, user.didi_id) == "editor"
    end

    test "re-adding updates the role rather than duplicating" do
      user = seed_user()
      entity = seed_entity("apollo")

      {:ok, _} = Entities.add_member(entity.id, user.didi_id, "viewer")
      {:ok, _} = Entities.add_member(entity.id, user.didi_id, "org_admin")

      assert length(Entities.list_members(entity.id)) == 1
      assert Entities.effective_role(entity.id, user.didi_id) == "org_admin"
    end

    test "rejects unknown user, unknown entity, bad role and bad via" do
      user = seed_user()
      entity = seed_entity("apollo")

      assert {:error, :unknown_user} = Entities.add_member(entity.id, "nobody", "editor")
      assert {:error, :unknown_entity} = Entities.add_member("nope", user.didi_id, "editor")
      assert {:error, :invalid_role} = Entities.add_member(entity.id, user.didi_id, "wizard")
      assert {:error, :invalid_via} = Entities.add_member(entity.id, user.didi_id, "editor", via: "vibes")
    end

    test "a person can belong to a project and nothing else" do
      user = seed_user()
      project = seed_entity("apollo", "project")
      {:ok, _} = Entities.add_member(project.id, user.didi_id, "editor")

      assert [e] = Entities.list_entities_for(user.didi_id)
      assert e.id == project.id
    end
  end

  describe "the independence invariant (Ruling 1b)" do
    test "removing a member from one entity leaves other memberships intact" do
      user = seed_user()
      org = seed_entity("acme", "organization")
      workspace = seed_entity("q3", "workspace")
      project = seed_entity("apollo", "project")

      for e <- [org, workspace, project] do
        {:ok, _} = Entities.add_member(e.id, user.didi_id, "editor")
      end

      # Remove from the organization.
      :ok = Entities.remove_member(org.id, user.didi_id)

      assert Entities.effective_role(org.id, user.didi_id) == nil
      # Both others survive — the org contains nothing.
      assert Entities.effective_role(workspace.id, user.didi_id) == "editor"
      assert Entities.effective_role(project.id, user.didi_id) == "editor"

      # And the reverse direction: removing from the workspace leaves the project.
      :ok = Entities.remove_member(workspace.id, user.didi_id)
      assert Entities.effective_role(workspace.id, user.didi_id) == nil
      assert Entities.effective_role(project.id, user.didi_id) == "editor"
    end

    test "also_member_of/2 powers the removal disclosure" do
      user = seed_user()
      org = seed_entity("acme", "organization")
      project = seed_entity("apollo", "project")
      workspace = seed_entity("q3", "workspace")

      for e <- [org, project, workspace] do
        {:ok, _} = Entities.add_member(e.id, user.didi_id, "editor")
      end

      survivors = Entities.also_member_of(user.didi_id, org.id)
      slugs = Enum.map(survivors, & &1.slug) |> Enum.sort()

      assert slugs == ["apollo", "q3"]
    end
  end
end
