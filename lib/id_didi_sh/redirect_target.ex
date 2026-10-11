defmodule IdDidiSh.RedirectTarget do
  @moduledoc """
  The one rule for where a person may be sent after signing in.

  A destination is a same-site path and nothing else: a single leading `/`
  followed by a character that is neither `/` nor `\\`, no scheme, no host, no
  whitespace or control characters, and a path part that still obeys all of
  that once percent-decoded (`/%2F%2Fhost` is refused; an encoded URL inside
  the query string, as the OAuth way back carries, is fine). Browsers read
  `//host` and `/\\host` as "another site", and strip tabs and newlines before
  they parse, so each of those has to be refused here rather than trusted to
  the browser.

  Every place a destination is accepted (`next` on `POST /api/magic-links`,
  `return_to` on `/auth`, invites) cleans it with `sanitize/1` before it is
  stored, and every place one is used (`POST /access`, the `next` field of
  `POST /api/magic-links/redeem`) cleans it again, so a row written before
  this rule existed cannot slip through.

  `sanitize/1` returns the path unchanged when it is safe and `nil` otherwise.
  `nil` means "the default destination": the signed-in page on `/access`, and
  no `next` in the API.
  """

  @max_length 2048

  @spec sanitize(term()) :: String.t() | nil
  def sanitize(value) when is_binary(value) and byte_size(value) <= @max_length do
    with true <- local_path?(value),
         %URI{scheme: nil, host: nil, userinfo: nil, port: nil, path: path}
         when is_binary(path) <- URI.parse(value),
         {:ok, decoded_path} <- decode(path),
         true <- local_path?(decoded_path, :decoded) do
      value
    else
      _ -> nil
    end
  end

  def sanitize(_), do: nil

  # A single "/", then a character that does not start a second slash, no
  # backslash anywhere, and no space or control character. The raw value must
  # be visible ASCII only; once decoded, the path may hold UTF-8 (an encoded
  # "/caf%C3%A9" is a real page) but still nothing below 0x21 and no DEL.
  # "/" alone is the site root and is fine.
  defp local_path?(path, form \\ :raw)
  defp local_path?("/", _form), do: true

  defp local_path?(<<"/", second, _::binary>> = path, form) when second not in [?/, ?\\] do
    not String.contains?(path, "\\") and allowed_bytes?(path, form)
  end

  defp local_path?(_, _form), do: false

  defp allowed_bytes?(path, :raw), do: all_bytes?(path, &(&1 in 0x21..0x7E))
  defp allowed_bytes?(path, :decoded), do: all_bytes?(path, &(&1 > 0x20 and &1 != 0x7F))

  defp all_bytes?(path, fun), do: path |> :binary.bin_to_list() |> Enum.all?(fun)

  defp decode(value) do
    {:ok, URI.decode(value)}
  rescue
    ArgumentError -> :error
  end
end
