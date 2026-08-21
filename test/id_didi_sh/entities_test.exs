defmodule IdDidiSh.EntitiesTest do
  use IdDidiSh.DataCase, async: false

  alias IdDidiSh.Accounts
  alias IdDidiSh.Entities
  alias IdDidiSh.Entities.Entity
  alias IdDidiSh.Repo

  defp seed_user(email \\ "alice@example.com") do
    {:ok, user} = Accounts.create_user(%{primary_email: email, name: "Alice"})
    user
  end

  defp seed_entity(slug, kind \\ "project") do
    {:ok, entity} = Entities.create_entity(%{kind: kind, slug: slug, name: String.upcase(slug)})
    entity
  end

  defp seed_domain_entity(slug, domain) do
    {:ok, entity} =
      Entities.create_entity(%{
        kind: "organization",
        slug: slug,
        name: String.upcase(slug),
        default_domain: domain
      })

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

      assert {:error, :slug_taken} =
               Entities.create_entity(%{kind: "project", slug: "apollo", name: "Apollo II"})
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

      assert {:error, :invalid_via} =
               Entities.add_member(entity.id, user.didi_id, "editor", via: "vibes")
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

  # The workspaces model (retired with `hygene/test-coverage`) guarded these
  # with five tests. `entities` inherited `default_domain` as a COLUMN but not
  # the guards: it is written once on create and never read again, and
  # `effective_role/2` consults only lending and the membership row.
  #
  # That is correct, and nothing was asserting it. These tests are what keep it
  # true — the failure mode is a future reader seeing the column and wiring it
  # into `effective_role/2`, which reintroduces domain-derived membership and
  # makes an advisor structurally inexpressible.
  describe "default_domain is inert (the advisor invariant)" do
    test "a matching email domain confers no access by itself" do
      entity = seed_domain_entity("acme", "acme.com")
      user = seed_user("bob@acme.com")

      # No membership row was ever created. The domain must not stand in for one.
      assert Entities.get_membership(entity.id, user.didi_id) == nil
      assert Entities.effective_role(entity.id, user.didi_id) == nil
      assert Entities.list_entities_for(user.didi_id) == []
    end

    test "an advisor at another company holds a role, and moving the domain revokes nobody" do
      entity = seed_domain_entity("acme", "acme.com")
      advisor = seed_user("dana@other-firm.com")

      # Membership is an explicit grant; the granted person's address is
      # irrelevant to it.
      {:ok, _} = Entities.add_member(entity.id, advisor.didi_id, "editor")
      assert Entities.effective_role(entity.id, advisor.didi_id) == "editor"

      entity
      |> Ecto.Changeset.change(default_domain: "somewhere-else.com")
      |> Repo.update!()

      assert Entities.effective_role(entity.id, advisor.didi_id) == "editor"

      Entities.get_entity(entity.id)
      |> Ecto.Changeset.change(default_domain: nil)
      |> Repo.update!()

      assert Entities.effective_role(entity.id, advisor.didi_id) == "editor"
    end
  end

  describe "bookkeeping" do
    test "slugs are compared exactly — casing yields a distinct entity" do
      seed_entity("apollo")

      # Characterisation, not endorsement. `create_entity/1` takes the slug raw
      # and only rejects an exact duplicate, so these are two entities. The
      # retired workspaces model normalised instead. If normalising is what we
      # want, this test is the one that should change.
      assert {:ok, other} =
               Entities.create_entity(%{kind: "project", slug: "Apollo", name: "Apollo II"})

      assert other.slug == "Apollo"
      refute other.id == Entities.get_entity_by_slug("apollo").id
    end

    test "remove_member is idempotent, and via records how someone got in" do
      user = seed_user()
      entity = seed_entity("apollo")

      {:ok, m} = Entities.add_member(entity.id, user.didi_id, "editor")
      # via defaults to "invite" — the only account-creation path this service has.
      assert m.via == "invite"

      {:ok, m2} = Entities.add_member(entity.id, user.didi_id, "viewer", via: "auto_join")
      assert m2.via == "invite", "on_conflict replaces role only, so via stays as first recorded"

      assert :ok = Entities.remove_member(entity.id, user.didi_id)
      assert Entities.effective_role(entity.id, user.didi_id) == nil
      # Removing again is not an error — the caller should not have to check first.
      assert :ok = Entities.remove_member(entity.id, user.didi_id)
      assert Entities.effective_role(entity.id, user.didi_id) == nil
    end
  end
end
