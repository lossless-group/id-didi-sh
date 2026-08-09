defmodule IdDidiSh.Repo.Migrations.Workspaces do
  use Ecto.Migration

  # Workspaces become the tenancy boundary and the boundary secrets attach to,
  # per the 2026-08-09 amendment in ai-labs/context-v/specs/
  # Id-Didi-Sh-Identity-Service.md.
  #
  # The reason, in one line: the people who most need access to a client's
  # workspace are precisely the ones whose email will never match its domain —
  # advisors, investors, fractional operators, and the person administering it
  # from another company's address. Derive membership from a domain and you have
  # built a system that structurally cannot express an advisor.
  #
  # So `default_domain` here is a SELF-SIGNUP HINT and nothing else. It says "an
  # address at this domain may join without an invite". It is never consulted to
  # decide whether an existing member has access — auto-join writes an ordinary
  # membership row, and from that moment the row is the authority. Clearing the
  # domain therefore cannot revoke anyone, which is the property that makes it
  # safe to change.

  def change do
    create table(:workspaces, primary_key: false) do
      add :id, :string, primary_key: true
      add :slug, :string, null: false
      add :name, :string, null: false

      # Nullable on purpose: a workspace may precede its org (a client exists
      # before anyone has decided what their canonical domain is) or outlive it.
      add :org_id, references(:organizations, type: :string, on_delete: :nilify_all)

      # Self-signup convenience only. See the note above.
      add :default_domain, :string
      add :default_role, :string, null: false, default: "viewer"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspaces, [:slug])
    create index(:workspaces, [:org_id])
    # Lowered, because a domain typed with capitals is the same domain.
    create index(:workspaces, ["lower(default_domain)"], name: :workspaces_default_domain_index)

    create table(:workspace_memberships) do
      add :didi_id, references(:users, column: :didi_id, type: :string, on_delete: :delete_all),
        null: false

      add :workspace_id, references(:workspaces, type: :string, on_delete: :delete_all),
        null: false

      add :role, :string, null: false

      # How this person got in. The question that matters a year later, when an
      # advisor still has access and nobody remembers granting it.
      add :via, :string, null: false, default: "invite"
      add :granted_by, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspace_memberships, [:didi_id, :workspace_id])
    create index(:workspace_memberships, [:workspace_id])
  end
end
