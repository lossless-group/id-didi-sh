defmodule IdDidiSh.Accounts.InviteNotifierTest do
  use ExUnit.Case, async: true

  import Swoosh.TestAssertions

  alias IdDidiSh.Accounts.InviteNotifier

  test "the intro and subject name whoever and whatever is known" do
    cases = [
      {[], "You have been invited to didi.sh.", "You've been invited to didi.sh"},
      {[entity_name: "Apollo"], "You have been invited to join Apollo.",
       "You've been invited to Apollo"},
      {[inviter_name: "Dana"], "Dana invited you to didi.sh.", "You've been invited to didi.sh"},
      {[inviter_name: "Dana", entity_name: "Apollo"], "Dana invited you to join Apollo.",
       "You've been invited to Apollo"}
    ]

    for {opts, intro, subject} <- cases do
      {:ok, _} = InviteNotifier.deliver("p@firm.test", "raw-token", opts)

      assert_email_sent(fn email ->
        assert email.subject == subject
        assert email.text_body =~ intro
        assert email.text_body =~ "/access?token=raw-token"
        assert email.to == [{"", "p@firm.test"}]
      end)
    end
  end
end
