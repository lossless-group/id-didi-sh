defmodule Mix.Tasks.IdTasksTest do
  @moduledoc """
  The operator tasks. They are how production gets its first users and
  entities, so a task that silently does nothing is a real outage. Each is
  run in-process against the sandbox with `Mix.Shell.Process`, so its output
  arrives as messages to assert on.
  """
  use IdDidiSh.DataCase, async: false

  alias IdDidiSh.{Accounts, Entities}

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  defp info do
    assert_received {:mix_shell, :info, [msg]}
    msg
  end

  defp error do
    assert_received {:mix_shell, :error, [msg]}
    msg
  end

  describe "id.seed" do
    test "creates a user, with or without a name" do
      Mix.Tasks.Id.Seed.run(["ada@firm.test", "Ada", "Lovelace"])
      assert info() =~ "created ada@firm.test didi_id="
      assert Accounts.get_user_by_email("ada@firm.test").name == "Ada Lovelace"

      Mix.Tasks.Id.Seed.run(["nameless@firm.test"])
      assert info() =~ "created nameless@firm.test"
      assert Accounts.get_user_by_email("nameless@firm.test").name == nil
    end

    test "reports a failure and prints usage with no args" do
      Mix.Tasks.Id.Seed.run(["not-an-email"])
      assert error() =~ "failed:"

      Mix.Tasks.Id.Seed.run([])
      assert error() =~ "usage: mix id.seed"
    end
  end

  describe "id.org and id.member" do
    test "upserts an org and a membership into it" do
      {:ok, _} = Accounts.create_user(%{primary_email: "ada@firm.test"})

      Mix.Tasks.Id.Org.run(["Firm.Test", "The", "Firm"])
      assert info() =~ "org firm.test (The Firm) slug=firm-test"

      Mix.Tasks.Id.Member.run(["ada@firm.test", "firm.test", "editor"])
      assert info() == "ada@firm.test → firm.test as editor"
    end

    test "id.member refuses an unknown user and a bad role" do
      {:ok, _} = Accounts.create_user(%{primary_email: "ada@firm.test"})

      Mix.Tasks.Id.Member.run(["ghost@firm.test", "firm.test", "editor"])
      assert error() == "no user found for ghost@firm.test"

      Mix.Tasks.Id.Member.run(["ada@firm.test", "firm.test", "emperor"])
      assert error() =~ "failed:"
    end

    test "both print usage on bad arity" do
      Mix.Tasks.Id.Org.run(["only-a-domain"])
      assert error() =~ "usage: mix id.org"

      Mix.Tasks.Id.Member.run([])
      assert error() =~ "usage: mix id.member"
    end
  end

  describe "id.alias" do
    test "attaches an alias, resolving the user by email or didi_id" do
      {:ok, user} = Accounts.create_user(%{primary_email: "ada@firm.test"})

      Mix.Tasks.Id.Alias.run(["ada@firm.test", "ada@home.test"])
      assert info() =~ "ada@home.test → ada@firm.test"

      Mix.Tasks.Id.Alias.run([user.didi_id, "ada@work.test"])
      assert info() =~ "aliases: "

      assert Enum.sort(Accounts.list_email_aliases(user.didi_id)) == [
               "ada@home.test",
               "ada@work.test"
             ]
    end

    test "refuses an unknown user, a bad alias, and bad arity" do
      {:ok, _} = Accounts.create_user(%{primary_email: "ada@firm.test"})

      Mix.Tasks.Id.Alias.run(["ghost@firm.test", "x@y.z"])
      assert error() == "no user found for ghost@firm.test"

      Mix.Tasks.Id.Alias.run(["ada@firm.test", "nope"])
      assert error() == "failed: invalid_email"

      Mix.Tasks.Id.Alias.run([])
      assert error() =~ "usage: mix id.alias"
    end
  end

  describe "id.entity" do
    test "new, add, and ls" do
      {:ok, _} = Accounts.create_user(%{primary_email: "ada@firm.test"})

      Mix.Tasks.Id.Entity.run(["ls"])
      assert info() == "(no entities)"

      Mix.Tasks.Id.Entity.run(["new", "project", "apollo", "Apollo", "Program"])
      assert info() =~ "project/apollo  Apollo Program"

      Mix.Tasks.Id.Entity.run(["ls", "apollo"])
      assert info() =~ "project/apollo"
      assert info() == "  (no members)"

      Mix.Tasks.Id.Entity.run(["add", "apollo", "ada@firm.test", "editor"])
      assert info() == "ada@firm.test is editor in project/apollo"

      Mix.Tasks.Id.Entity.run(["ls"])
      assert info() =~ "project/apollo  Apollo Program"

      Mix.Tasks.Id.Entity.run(["ls", "apollo"])
      _header = info()
      assert info() == "  ada@firm.test  editor  via=seed"
    end

    test "ls shows a member with no account by didi_id" do
      {:ok, e} = Entities.create_entity(%{kind: "project", slug: "apollo", name: "Apollo"})
      {:ok, ghost} = Accounts.create_user(%{primary_email: "ghost@firm.test"})
      {:ok, _} = Entities.add_member(e.id, ghost.didi_id, "viewer", via: "seed")

      # Detach the user row without cascading the membership away.
      IdDidiSh.Repo.query!("PRAGMA defer_foreign_keys = ON")

      IdDidiSh.Repo.query!("UPDATE entity_memberships SET didi_id = 'gone' WHERE entity_id = ?", [
        e.id
      ])

      Mix.Tasks.Id.Entity.run(["ls", "apollo"])
      _header = info()
      assert info() == "  gone  viewer  via=seed"
    end

    test "raises with a reason on every failure" do
      Entities.create_entity(%{kind: "project", slug: "apollo", name: "Apollo"})

      assert_raise Mix.Error, ~r/could not create entity/, fn ->
        Mix.Tasks.Id.Entity.run(["new", "squad", "x", "X"])
      end

      assert_raise Mix.Error, ~r/unknown_entity/, fn ->
        Mix.Tasks.Id.Entity.run(["add", "nowhere", "ada@firm.test", "editor"])
      end

      assert_raise Mix.Error, ~r/unknown_user/, fn ->
        Mix.Tasks.Id.Entity.run(["add", "apollo", "ghost@firm.test", "editor"])
      end

      assert_raise Mix.Error, ~r/no entity with slug nowhere/, fn ->
        Mix.Tasks.Id.Entity.run(["ls", "nowhere"])
      end

      assert_raise Mix.Error, ~r/usage:/, fn -> Mix.Tasks.Id.Entity.run([]) end
    end
  end

  describe "id.gen.keypair" do
    test "prints a private Ed25519 JWK whose public half and kid match" do
      Mix.Tasks.Id.Gen.Keypair.run([])
      out = info()

      [private_json, public_json] =
        out |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "{"))

      private = Jason.decode!(private_json)
      public = Jason.decode!(public_json)

      assert private["kty"] == "OKP" and private["crv"] == "Ed25519"
      assert Map.has_key?(private, "d")
      refute Map.has_key?(public, "d")
      assert public["x"] == private["x"]
      assert out =~ "kid = #{JOSE.JWK.thumbprint(JOSE.JWK.from_map(private))}"
    end
  end

  describe "id.email.test" do
    import Swoosh.TestAssertions

    test "sends through the configured mailer and reports it" do
      Mix.Tasks.Id.Email.Test.run(["ops@firm.test"])

      assert info() =~ "sent ✓"

      assert_email_sent(
        subject: "didi.sh test — the email pipe works",
        to: [{"", "ops@firm.test"}]
      )
    end

    test "prints usage without exactly one address" do
      Mix.Tasks.Id.Email.Test.run([])
      assert error() =~ "usage: mix id.email.test"
    end
  end
end
