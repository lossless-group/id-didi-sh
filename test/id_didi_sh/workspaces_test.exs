defmodule IdDidiSh.WorkspacesTest do
  @moduledoc """
  The workspace model, and the three invariants it exists to protect.

  These are not abstract properties. Each one is here because the alternative
  cannot express a real person the operator works with every week — the advisor
  at another company, the investor with a personal address, the operator
  administering palmer-ai from a humain.vc account.

  The tests under "the invariant" are the ones that must never be relaxed to make
  something else pass.
  """

  use IdDidiSh.DataCase, async: false

  alias IdDidiSh.Accounts
  alias IdDidiSh.Workspaces

  defp user(email) do
    {:ok, u} = Accounts.create_user(%{primary_email: email, name: email})
    u
  end

  defp workspace(slug, opts \\ []) do
    {:ok, w} = Workspaces.upsert_workspace(slug, opts[:name] || slug, opts)
    w
  end

  describe "workspaces" do
    test "upsert by slug, and slugs are normalized" do
      {:ok, a} = Workspaces.upsert_workspace("  Reach-EDU  ", "Reach Edu")
      assert a.slug == "reach-edu"

      {:ok, b} = Workspaces.upsert_workspace("reach-edu", "Reach Education")
      assert b.slug == "reach-edu"
      assert Workspaces.get_workspace("reach-edu").name == "Reach Education"
    end

    test "a workspace may precede its organization" do
      # A client exists before anyone has decided their canonical domain.
      {:ok, w} = Workspaces.upsert_workspace("brand-new-client", "Brand New Client")
      assert is_nil(w.org_id)
      assert Workspaces.get_workspace("brand-new-client")
    end

    test "rejects an unknown default role" do
      assert {:error, :invalid_role} =
               Workspaces.upsert_workspace("x", "X", default_role: "emperor")
    end
  end

  describe "membership" do
    test "grant then read back the role" do
      u = user("alice@example.com")
      workspace("reach-edu")

      assert {:ok, _} = Workspaces.grant(u.didi_id, "reach-edu", "editor")
      assert {:ok, "editor"} = Workspaces.role_of(u.didi_id, "reach-edu")
      assert Workspaces.member?(u.didi_id, "reach-edu")
    end

    test "granting twice updates the role rather than duplicating" do
      u = user("alice@example.com")
      workspace("reach-edu")

      {:ok, _} = Workspaces.grant(u.didi_id, "reach-edu", "viewer")
      {:ok, _} = Workspaces.grant(u.didi_id, "reach-edu", "org_admin")

      assert {:ok, "org_admin"} = Workspaces.role_of(u.didi_id, "reach-edu")
      assert length(Workspaces.members("reach-edu")) == 1
    end

    test "revoke removes access and is idempotent" do
      u = user("alice@example.com")
      workspace("reach-edu")
      {:ok, _} = Workspaces.grant(u.didi_id, "reach-edu", "editor")

      assert {:ok, 1} = Workspaces.revoke(u.didi_id, "reach-edu")
      refute Workspaces.member?(u.didi_id, "reach-edu")
      assert {:ok, 0} = Workspaces.revoke(u.didi_id, "reach-edu")
    end

    test "records how someone got in" do
      u = user("alice@example.com")
      admin = user("admin@lossless.group")
      workspace("reach-edu")

      {:ok, _} =
        Workspaces.grant(u.didi_id, "reach-edu", "editor",
          via: "invite",
          granted_by: admin.didi_id
        )

      [m] = Workspaces.members("reach-edu")
      assert m.via == "invite"
      assert m.granted_by == admin.didi_id
    end

    test "rejects unknown user, workspace, role, and via" do
      u = user("alice@example.com")
      workspace("reach-edu")

      assert {:error, :unknown_user} = Workspaces.grant("nobody", "reach-edu", "editor")
      assert {:error, :unknown_workspace} = Workspaces.grant(u.didi_id, "nope", "editor")
      assert {:error, :invalid_role} = Workspaces.grant(u.didi_id, "reach-edu", "emperor")
      assert {:error, :invalid_via} = Workspaces.grant(u.didi_id, "reach-edu", "editor", via: "x")
    end
  end

  describe "the invariant: membership is email-domain-independent" do
    test "an advisor at another company can hold a role" do
      # The case a domain-derived model structurally cannot express.
      advisor = user("advisor@some-vc-fund.com")
      workspace("reach-edu", default_domain: "reach.edu")

      assert {:ok, _} = Workspaces.grant(advisor.didi_id, "reach-edu", "viewer")
      assert {:ok, "viewer"} = Workspaces.role_of(advisor.didi_id, "reach-edu")
    end

    test "the operator administers a client from a different company's address" do
      # Verbatim from the field: palmer-ai accounts created on a humain.vc email.
      operator = user("michael@humain.vc")
      workspace("palmer-ai", default_domain: "palmer.ai")

      assert {:ok, _} = Workspaces.grant(operator.didi_id, "palmer-ai", "org_admin")
      assert {:ok, "org_admin"} = Workspaces.role_of(operator.didi_id, "palmer-ai")
    end

    test "a workspace with NO default domain still grants normally" do
      u = user("someone@anywhere.com")
      workspace("no-domain-here")

      assert {:ok, _} = Workspaces.grant(u.didi_id, "no-domain-here", "editor")
      assert Workspaces.member?(u.didi_id, "no-domain-here")
    end

    test "changing or clearing the domain does not revoke anyone" do
      # The property that makes default_domain safe to edit. If access were
      # derived from it, this edit would silently cut off every member.
      advisor = user("advisor@some-vc-fund.com")
      workspace("reach-edu", default_domain: "reach.edu")
      {:ok, _} = Workspaces.grant(advisor.didi_id, "reach-edu", "editor")

      {:ok, _} = Workspaces.upsert_workspace("reach-edu", "Reach Edu", default_domain: nil)
      assert {:ok, "editor"} = Workspaces.role_of(advisor.didi_id, "reach-edu")

      {:ok, _} =
        Workspaces.upsert_workspace("reach-edu", "Reach Edu", default_domain: "elsewhere.org")

      assert {:ok, "editor"} = Workspaces.role_of(advisor.didi_id, "reach-edu")
    end

    test "one login lists every workspace, however each was set up" do
      operator = user("michael@humain.vc")
      workspace("reach-edu", default_domain: "reach.edu")
      workspace("palmer-ai", default_domain: "palmer.ai")
      workspace("lossless", default_domain: "lossless.group")

      for slug <- ~w(reach-edu palmer-ai lossless) do
        {:ok, _} = Workspaces.grant(operator.didi_id, slug, "org_admin")
      end

      slugs = Workspaces.for_user(operator.didi_id) |> Enum.map(& &1.slug)
      assert slugs == ~w(lossless palmer-ai reach-edu)
    end
  end

  describe "the invariant: default_domain is a signup hint, not an access check" do
    test "a matching domain does NOT by itself confer access" do
      # The sharp edge. Sharing a domain is an invitation to ask, not entry.
      stranger = user("stranger@reach.edu")
      workspace("reach-edu", default_domain: "reach.edu")

      refute Workspaces.member?(stranger.didi_id, "reach-edu")
      assert Workspaces.role_of(stranger.didi_id, "reach-edu") == :error
      assert Workspaces.for_user(stranger.didi_id) == []
    end

    test "joinable_by_email surfaces where a stranger could let themselves in" do
      workspace("reach-edu", default_domain: "reach.edu", default_role: "viewer")
      workspace("palmer-ai", default_domain: "palmer.ai")

      assert [%{slug: "reach-edu", default_role: "viewer"}] =
               Workspaces.joinable_by_email("newhire@REACH.edu")

      assert Workspaces.joinable_by_email("advisor@some-vc-fund.com") == []
      assert Workspaces.joinable_by_email("not-an-email") == []
    end

    test "auto_join writes an ordinary membership row" do
      newhire = user("newhire@reach.edu")
      workspace("reach-edu", default_domain: "reach.edu", default_role: "viewer")

      assert {:ok, _} = Workspaces.auto_join(newhire.didi_id, "reach-edu")
      assert {:ok, "viewer"} = Workspaces.role_of(newhire.didi_id, "reach-edu")

      [m] = Workspaces.members("reach-edu")
      assert m.via == "auto_join"
    end

    test "auto_join refuses a mismatched domain, and refuses when none is set" do
      advisor = user("advisor@some-vc-fund.com")
      workspace("reach-edu", default_domain: "reach.edu")
      workspace("private-thing")

      assert {:error, :domain_mismatch} = Workspaces.auto_join(advisor.didi_id, "reach-edu")
      assert {:error, :no_default_domain} = Workspaces.auto_join(advisor.didi_id, "private-thing")
    end

    test "an email ALIAS at the domain is enough to auto-join" do
      # One person, many addresses is already the norm here; requiring the
      # primary would make aliases useless for exactly what they exist for.
      u = user("personal@gmail.com")
      {:ok, _} = Accounts.add_email_alias(u, "work@reach.edu")
      workspace("reach-edu", default_domain: "reach.edu")

      assert {:ok, _} = Workspaces.auto_join(u.didi_id, "reach-edu")
      assert Workspaces.member?(u.didi_id, "reach-edu")
    end

    test "an auto-joined member survives the domain being cleared" do
      newhire = user("newhire@reach.edu")
      workspace("reach-edu", default_domain: "reach.edu")
      {:ok, _} = Workspaces.auto_join(newhire.didi_id, "reach-edu")

      {:ok, _} = Workspaces.upsert_workspace("reach-edu", "Reach Edu", default_domain: nil)

      assert {:ok, "viewer"} = Workspaces.role_of(newhire.didi_id, "reach-edu")
    end
  end
end
