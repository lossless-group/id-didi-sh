defmodule IdDidiSh.Workspaces do
  @moduledoc """
  Workspaces: the tenancy boundary, and the boundary secrets attach to.

  Per the 2026-08-09 amendment to
  `ai-labs/context-v/specs/Id-Didi-Sh-Identity-Service.md`. Three invariants
  live in this module, and every one of them exists because the alternative
  cannot express a real person the operator works with every week:

  1. **Membership is explicit and email-domain-independent.** Anyone may hold any
     role in any workspace, whatever their address. Advisors, investors,
     fractional operators, and the person administering a client's stack from
     another company's address are the NORMAL case, not the exception.

  2. **`default_domain` is a self-signup hint, never an access check.** It
     answers "may this stranger join without an invite?" and nothing else.
     `member?/2` never looks at it. Consequently, clearing or changing a domain
     cannot revoke anybody — which is what makes the field safe to edit.

  3. **Auto-join writes an ordinary row.** There is no second class of
     membership. Once someone is in, the row is the authority and `via` merely
     records the history.

  A separate `Accounts.memberships` (org-level) table is retained for org-wide
  roles such as `superuser`. This module does not consult it — deliberately, so
  that workspace access has exactly one source.
  """

  import Ecto.Query, warn: false

  alias IdDidiSh.Accounts
  alias IdDidiSh.Accounts.Workspace
  alias IdDidiSh.Accounts.WorkspaceMembership
  alias IdDidiSh.Repo
  alias IdDidiSh.UUID7

  ## Workspaces

  @doc """
  Upsert a workspace by slug.

  `org_id` may be nil: a workspace can precede its organization, which happens
  whenever a client exists before anyone has decided what their canonical domain
  is.
  """
  def upsert_workspace(slug, name, opts \\ []) do
    slug = normalize_slug(slug)
    default_role = Keyword.get(opts, :default_role, "viewer")

    cond do
      slug == "" ->
        {:error, :invalid_slug}

      default_role not in WorkspaceMembership.roles() ->
        {:error, :invalid_role}

      true ->
        attrs = %Workspace{
          id: UUID7.generate(),
          slug: slug,
          name: name,
          org_id: opts |> Keyword.get(:org_id) |> normalize_domain(),
          default_domain: opts |> Keyword.get(:default_domain) |> normalize_domain(),
          default_role: default_role
        }

        Repo.insert(attrs,
          on_conflict: {:replace, [:name, :org_id, :default_domain, :default_role, :updated_at]},
          conflict_target: :slug
        )
    end
  end

  def get_workspace(slug), do: Repo.get_by(Workspace, slug: normalize_slug(slug))

  def get_workspace_by_id(id), do: Repo.get(Workspace, id)

  ## Membership

  @doc """
  Grant `didi_id` a role in a workspace.

  Upsert-by-natural-key: granting twice updates the role rather than duplicating
  the row. **No domain check happens here, ever.** That is the invariant — the
  grant is the authority, and the granted person's email address is irrelevant to
  it.
  """
  def grant(didi_id, workspace_slug, role, opts \\ []) do
    via = Keyword.get(opts, :via, "invite")
    workspace = get_workspace(workspace_slug)

    cond do
      role not in WorkspaceMembership.roles() -> {:error, :invalid_role}
      via not in WorkspaceMembership.vias() -> {:error, :invalid_via}
      is_nil(Accounts.get_user(didi_id)) -> {:error, :unknown_user}
      is_nil(workspace) -> {:error, :unknown_workspace}
      true -> do_grant(didi_id, workspace, role, via, Keyword.get(opts, :granted_by))
    end
  end

  defp do_grant(didi_id, workspace, role, via, granted_by) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(
      WorkspaceMembership,
      [
        %{
          didi_id: didi_id,
          workspace_id: workspace.id,
          role: role,
          via: via,
          granted_by: granted_by,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: {:replace, [:role, :updated_at]},
      conflict_target: [:didi_id, :workspace_id]
    )

    Accounts.record_event("workspace_granted", %{didi_id: didi_id})
    {:ok, get_membership(didi_id, workspace.id)}
  end

  @doc "Revoke access. Idempotent — revoking a non-member is not an error."
  def revoke(didi_id, workspace_slug) do
    case get_workspace(workspace_slug) do
      nil ->
        {:error, :unknown_workspace}

      workspace ->
        {count, _} =
          Repo.delete_all(
            from m in WorkspaceMembership,
              where: m.didi_id == ^didi_id and m.workspace_id == ^workspace.id
          )

        if count > 0, do: Accounts.record_event("workspace_revoked", %{didi_id: didi_id})
        {:ok, count}
    end
  end

  def get_membership(didi_id, workspace_id) do
    Repo.get_by(WorkspaceMembership, didi_id: didi_id, workspace_id: workspace_id)
  end

  @doc """
  Whether this person has access, and at what role.

  **Reads the membership row and nothing else.** No domain is consulted. This is
  the function the invariant is really about: if it ever grew a domain check,
  every advisor in the system would lose access the moment their client changed
  a setting.
  """
  def role_of(didi_id, workspace_slug) do
    with %Workspace{} = workspace <- get_workspace(workspace_slug),
         %WorkspaceMembership{role: role} <- get_membership(didi_id, workspace.id) do
      {:ok, role}
    else
      _ -> :error
    end
  end

  def member?(didi_id, workspace_slug), do: match?({:ok, _}, role_of(didi_id, workspace_slug))

  @doc """
  Every workspace this person may touch, with their role — by grant, regardless
  of what address they hold.

  This is what `GET /api/workspaces` returns, and what makes one login show
  reach-edu, palmer-ai and lossless side by side even though each was set up
  under a different email.
  """
  def for_user(didi_id) do
    Repo.all(
      from m in WorkspaceMembership,
        join: w in Workspace,
        on: w.id == m.workspace_id,
        where: m.didi_id == ^didi_id,
        order_by: w.slug,
        select: %{
          slug: w.slug,
          name: w.name,
          org_id: w.org_id,
          default_domain: w.default_domain,
          role: m.role,
          via: m.via
        }
    )
  end

  def members(workspace_slug) do
    case get_workspace(workspace_slug) do
      nil ->
        []

      workspace ->
        Repo.all(
          from m in WorkspaceMembership,
            where: m.workspace_id == ^workspace.id,
            order_by: m.didi_id,
            select: %{didi_id: m.didi_id, role: m.role, via: m.via, granted_by: m.granted_by}
        )
    end
  end

  ## Self-signup

  @doc """
  Workspaces a *stranger* at this email could join without an invite.

  The ONLY place `default_domain` is read. Note what this does not do: it does
  not tell you whether someone has access. It answers a different and much
  narrower question — "may this person let themselves in?" — and existing members
  are found by `for_user/1`, which never looks here.
  """
  def joinable_by_email(email) do
    case domain_of(email) do
      nil ->
        []

      domain ->
        Repo.all(
          from w in Workspace,
            where: fragment("lower(?)", w.default_domain) == ^domain,
            order_by: w.slug,
            select: %{slug: w.slug, name: w.name, default_role: w.default_role}
        )
    end
  end

  @doc """
  Let someone in on the strength of their email domain.

  Writes an ordinary membership row with `via: "auto_join"`. There is no second
  class of membership: from here on the row is the authority, so a later change
  to the workspace's domain leaves this person exactly where they are.
  """
  def auto_join(didi_id, workspace_slug) do
    user = Accounts.get_user(didi_id)
    workspace = get_workspace(workspace_slug)

    cond do
      is_nil(user) ->
        {:error, :unknown_user}

      is_nil(workspace) ->
        {:error, :unknown_workspace}

      is_nil(workspace.default_domain) ->
        {:error, :no_default_domain}

      not addressable?(user, workspace.default_domain) ->
        {:error, :domain_mismatch}

      true ->
        grant(didi_id, workspace_slug, workspace.default_role, via: "auto_join")
    end
  end

  # True when ANY of the person's addresses — primary or alias — is at this
  # domain. One person, many addresses is already the norm here; requiring the
  # primary would make an alias useless for exactly the case aliases exist for.
  defp addressable?(user, domain) do
    domain = String.downcase(domain)

    [user.primary_email | Accounts.list_email_aliases(user.didi_id)]
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(&(domain_of(&1) == domain))
  end

  defp domain_of(email) when is_binary(email) do
    case email |> String.trim() |> String.downcase() |> String.split("@") do
      [_, domain] when domain != "" -> domain
      _ -> nil
    end
  end

  defp domain_of(_), do: nil

  defp normalize_slug(nil), do: ""
  defp normalize_slug(slug), do: slug |> String.trim() |> String.downcase()

  defp normalize_domain(nil), do: nil

  defp normalize_domain(domain) do
    case domain |> String.trim() |> String.downcase() do
      "" -> nil
      value -> value
    end
  end
end
