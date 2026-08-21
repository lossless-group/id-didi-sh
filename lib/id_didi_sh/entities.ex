defmodule IdDidiSh.Entities do
  @moduledoc """
  The entities context: the flat tenancy primitive and its memberships.

  Three things here are invariants, not preferences. They are stated in the
  spec (`Flexible-Entity-Relationships-to-Mirror-Messy-IRL-Collaboration.md`)
  and re-stated here because each is the kind of thing a later reader
  "simplifies" into something tidier:

  1. **No hierarchy.** organization / workspace / project are labels. There is
     no `parent_id`, no containment, no inheritance. Projects are
     collaborations among many organizations; a tree cannot express that.

  2. **Memberships are independent.** Removing someone from one entity has no
     effect on their membership in any other, in either direction. A person who
     belongs to a project and nothing else is in a normal state.

  3. **Lending confers admin.** `effective_role/2` returns `:admin` for anyone
     with a live credential loan to the entity, whether or not they hold a
     membership row — the person with the credit card is frequently not on the
     project. Derived at call time, never stored, so it recedes on its own when
     the loan ends.
  """

  import Ecto.Query

  alias IdDidiSh.Repo
  alias IdDidiSh.UUID7
  alias IdDidiSh.Accounts
  alias IdDidiSh.Accounts.Membership
  alias IdDidiSh.Entities.{Entity, EntityMembership}

  ## Entities

  @doc """
  Create an entity. `kind` is a label — see the moduledoc.
  """
  def create_entity(attrs) when is_map(attrs) do
    kind = attrs[:kind] || attrs["kind"]
    slug = attrs[:slug] || attrs["slug"]
    name = attrs[:name] || attrs["name"]

    cond do
      kind not in Entity.kinds() ->
        {:error, :invalid_kind}

      is_nil(slug) or slug == "" ->
        {:error, :slug_required}

      is_nil(name) or name == "" ->
        {:error, :name_required}

      not is_nil(get_entity_by_slug(slug)) ->
        {:error, :slug_taken}

      true ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        entity = %Entity{
          id: UUID7.generate(),
          kind: kind,
          slug: slug,
          name: name,
          org_id: attrs[:org_id] || attrs["org_id"],
          default_domain: attrs[:default_domain] || attrs["default_domain"],
          default_role: attrs[:default_role] || attrs["default_role"],
          inserted_at: now,
          updated_at: now
        }

        Repo.insert(entity)
    end
  end

  def get_entity(id) when is_binary(id), do: Repo.get(Entity, id)
  def get_entity(_), do: nil

  def get_entity_by_slug(slug) when is_binary(slug), do: Repo.get_by(Entity, slug: slug)
  def get_entity_by_slug(_), do: nil

  def list_entities do
    Repo.all(from e in Entity, order_by: [asc: e.name])
  end

  @doc """
  Entities a person is a member of.

  Note: this is membership only. Someone may also have *access* to an entity
  purely by lending it a credential (see `effective_role/2`); once the
  credentials context exists this should union those in.
  """
  def list_entities_for(didi_id) when is_binary(didi_id) do
    Repo.all(
      from e in Entity,
        join: m in EntityMembership,
        on: m.entity_id == e.id,
        where: m.didi_id == ^didi_id,
        order_by: [asc: e.name]
    )
  end

  ## Memberships

  @doc """
  Add or update a membership.

  `opts` accepts `:granted_by` and `:via` (one of `EntityMembership.vias/0`,
  default `"invite"`).
  """
  def add_member(entity_id, didi_id, role, opts \\ []) do
    via = Keyword.get(opts, :via, "invite")
    granted_by = Keyword.get(opts, :granted_by)

    cond do
      role not in Membership.roles() ->
        {:error, :invalid_role}

      via not in EntityMembership.vias() ->
        {:error, :invalid_via}

      is_nil(Accounts.get_user(didi_id)) ->
        {:error, :unknown_user}

      is_nil(get_entity(entity_id)) ->
        {:error, :unknown_entity}

      true ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        {1, _} =
          Repo.insert_all(
            EntityMembership,
            [
              %{
                didi_id: didi_id,
                entity_id: entity_id,
                role: role,
                granted_by: granted_by,
                via: via,
                inserted_at: now,
                updated_at: now
              }
            ],
            on_conflict: {:replace, [:role, :updated_at]},
            conflict_target: [:didi_id, :entity_id]
          )

        {:ok, get_membership(entity_id, didi_id)}
    end
  end

  @doc """
  Remove one membership.

  Removes exactly this pair and nothing else — see invariant 2. Callers that
  present this to a human must also show `also_member_of/2`, so the person doing
  the removing can see what access survives.
  """
  def remove_member(entity_id, didi_id) do
    {_count, _} =
      Repo.delete_all(
        from m in EntityMembership,
          where: m.entity_id == ^entity_id and m.didi_id == ^didi_id
      )

    :ok
  end

  def get_membership(entity_id, didi_id) do
    Repo.get_by(EntityMembership, entity_id: entity_id, didi_id: didi_id)
  end

  def list_members(entity_id) do
    Repo.all(
      from m in EntityMembership,
        where: m.entity_id == ^entity_id,
        order_by: [asc: m.inserted_at]
    )
  end

  def memberships_for(didi_id) do
    Repo.all(
      from m in EntityMembership,
        where: m.didi_id == ^didi_id,
        order_by: [asc: m.inserted_at]
    )
  end

  @doc """
  Every OTHER entity this person still belongs to.

  Exists for the removal disclosure required by Ruling 1b: removing Alice from
  Acme must tell you she keeps access to Apollo and Q3 Diligence, or whoever
  clicked remove believes they offboarded someone who did not leave.
  """
  def also_member_of(didi_id, excluding_entity_id) do
    Repo.all(
      from e in Entity,
        join: m in EntityMembership,
        on: m.entity_id == e.id,
        where: m.didi_id == ^didi_id and e.id != ^excluding_entity_id,
        order_by: [asc: e.name]
    )
  end

  @doc """
  A person's effective role in an entity.

  The greater of their assigned membership role and `:admin` when they have a
  live credential loan to this entity. The loan half is not wired yet — the
  credentials context arrives in increment 4 — so today this returns the
  assigned role or nil. The shape is here so callers do not have to change.
  """
  def effective_role(entity_id, didi_id) do
    # INCREMENT 4 adds the first clause: if the person has a live credential
    # loan to this entity, return :admin regardless of membership. Deliberately
    # not stubbed — a stub that always returns false is a dead branch that
    # lies to the reader and to the type checker.
    case get_membership(entity_id, didi_id) do
      nil -> nil
      m -> m.role
    end
  end
end
