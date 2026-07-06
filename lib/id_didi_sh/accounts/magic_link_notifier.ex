defmodule IdDidiSh.Accounts.MagicLinkNotifier do
  @moduledoc """
  Magic-link email delivery via Swoosh. Dev uses the Local adapter
  (preview at /dev/mailbox); the production provider (Resend vs Postmark)
  is an open spec question — this module is the seam it lands in.
  """

  import Swoosh.Email

  alias IdDidiSh.Mailer

  def deliver(email, raw_token) do
    issuer =
      Application.get_env(:id_didi_sh, :identity, [])
      |> Keyword.get(:issuer, "https://id.didi.sh")

    new()
    |> to(email)
    |> from({"didi.sh", "no-reply@didi.sh"})
    |> subject("Your sign-in link")
    |> text_body("""
    Sign in with this single-use link (expires in 15 minutes):

    #{issuer}/access?token=#{raw_token}

    If you didn't request this, ignore it — nothing happens without the link.
    """)
    |> Mailer.deliver()
  end
end
