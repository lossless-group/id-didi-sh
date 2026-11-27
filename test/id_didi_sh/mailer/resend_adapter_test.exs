defmodule IdDidiSh.Mailer.ResendAdapterTest do
  @moduledoc """
  The hand-rolled Resend adapter, against a `Req.Test` stub — never the
  network. Pins the payload shape Resend expects and how each kind of failure
  comes back, because a magic link that silently fails to send looks exactly
  like an address that has no account.
  """
  use ExUnit.Case, async: true

  import Swoosh.Email

  alias IdDidiSh.Mailer.ResendAdapter

  defp config, do: [api_key: "re_test_key", req_options: [plug: {Req.Test, __MODULE__}]]

  defp email do
    new()
    |> to({"Dana", "dana@firm.test"})
    |> from({"didi.sh", "no-reply@didi.sh"})
    |> subject("Sign in")
    |> text_body("link")
  end

  test "posts the Resend payload with a bearer key, dropping empty fields" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn, Jason.decode!(body)})
      Req.Test.json(conn, %{"id" => "email_123"})
    end)

    assert {:ok, %{"id" => "email_123"}} = ResendAdapter.deliver(email(), config())

    assert_received {:request, conn, payload}
    assert conn.method == "POST"
    assert conn.request_path == "/emails"
    assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer re_test_key"]

    assert payload == %{
             "from" => "didi.sh <no-reply@didi.sh>",
             "to" => ["Dana <dana@firm.test>"],
             "subject" => "Sign in",
             "text" => "link"
           }
  end

  test "bare addresses and a reply-to are formatted as Resend expects" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:payload, Jason.decode!(body)})
      Req.Test.json(conn, %{})
    end)

    mail =
      new()
      |> to("plain@firm.test")
      |> from({"", "no-reply@didi.sh"})
      |> reply_to("help@didi.sh")
      |> subject("s")
      |> html_body("<p>h</p>")

    {:ok, _} = ResendAdapter.deliver(mail, config())

    assert_received {:payload, payload}
    assert payload["to"] == ["plain@firm.test"]
    assert payload["from"] == "no-reply@didi.sh"
    assert payload["reply_to"] == "help@didi.sh"
    assert payload["html"] == "<p>h</p>"
  end

  test "a non-2xx response is an error carrying the status and body" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"message" => "domain not verified"})
    end)

    assert {:error, {422, %{"message" => "domain not verified"}}} =
             ResendAdapter.deliver(email(), config())
  end

  test "a transport failure is an error, not a crash" do
    Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, %Req.TransportError{reason: :econnrefused}} =
             ResendAdapter.deliver(email(), config())
  end

  test "an api key is required config" do
    assert_raise ArgumentError, fn -> ResendAdapter.validate_config([]) end
  end
end
