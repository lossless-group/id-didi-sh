defmodule IdDidiSh.Credentials do
  @moduledoc """
  Credentials people lend to entities.

  The one rule that shapes every function here: **an entity never owns a
  credential.** A person lends one and keeps title throughout. Ending the loan
  takes the key back; the entity keeps everything it made with it.

  Two invariants, held firmly because they are what makes "lending" mean lending
  rather than giving away:

  1. **A borrower can never read the value.** No function here returns plaintext
     except `resolve/4` (increment 5), which is authenticated as a registered
     server-side app, not as a person. `render/1` is the only serializer, and it
     structurally cannot emit the value.
  2. **Every use is attributed.** Without it the lender cannot make an informed
     decision about staying lent, so the rational move becomes never lending.

  Lending itself (cascades, loans) arrives in increment 4; this module currently
  covers create / list / revoke.
  """

  import Ecto.Query

  alias IdDidiSh.Repo
  alias IdDidiSh.UUID7
  alias IdDidiSh.Accounts
  alias IdDidiSh.Credentials.Credential

  @providers ~w(anthropic openai google decile streak firecrawl tavily other)

  def providers, do: @providers

  @doc """
  Store a credential owned by a person.

  The raw value is encrypted at rest by `IdDidiSh.Vault`. `last_four` is kept in
  plaintext so a human can tell two keys apart without ever seeing either.
  """
  def create_credential(owner_didi_id, provider, label, raw_value)
      when is_binary(raw_value) do
    cond do
      provider not in @providers ->
        {:error, :invalid_provider}

      is_nil(Accounts.get_user(owner_didi_id)) ->
        {:error, :unknown_user}

      String.trim(raw_value) == "" ->
        {:error, :empty_value}

      is_nil(label) or String.trim(to_string(label)) == "" ->
        {:error, :label_required}

      true ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        Repo.insert(%Credential{
          id: UUID7.generate(),
          owner_didi_id: owner_didi_id,
          provider: provider,
          label: label,
          value_encrypted: raw_value,
          last_four: last_four(raw_value),
          inserted_at: now,
          updated_at: now
        })
    end
  end

  def create_credential(_, _, _, _), do: {:error, :empty_value}

  @doc "Credentials this person owns. Live ones first; revoked kept for the record."
  def list_credentials(owner_didi_id) do
    Repo.all(
      from c in Credential,
        where: c.owner_didi_id == ^owner_didi_id,
        order_by: [asc: c.revoked_at, desc: c.inserted_at]
    )
  end

  def get_credential(id) when is_binary(id), do: Repo.get(Credential, id)
  def get_credential(_), do: nil

  @doc """
  Revoke a credential. Only the owner may — it is their key.

  The row is kept rather than deleted so `credential_usage` stays meaningful:
  the lender's record of what their card paid for should survive the key.
  """
  def revoke_credential(id, by_didi_id) do
    case get_credential(id) do
      nil ->
        {:error, :not_found}

      %Credential{owner_didi_id: owner} when owner != by_didi_id ->
        {:error, :not_the_owner}

      %Credential{revoked_at: %DateTime{}} = c ->
        {:ok, c}

      credential ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        credential
        |> Ecto.Changeset.change(revoked_at: now, updated_at: now)
        |> Repo.update()
    end
  end

  def live?(%Credential{revoked_at: nil}), do: true
  def live?(%Credential{}), do: false

  @doc """
  The ONLY serializer for a credential.

  Deliberately built by naming safe fields rather than by dropping unsafe ones:
  a future field is invisible until someone adds it here, which is the failure
  direction you want.
  """
  def render(%Credential{} = c) do
    %{
      id: c.id,
      provider: c.provider,
      label: c.label,
      last_four: c.last_four,
      owner_didi_id: c.owner_didi_id,
      revoked_at: c.revoked_at,
      created_at: c.inserted_at
    }
  end

  # Enough to recognise a key, not enough to use one. Short values are masked
  # entirely rather than half-shown.
  defp last_four(value) do
    trimmed = String.trim(value)
    if String.length(trimmed) < 8, do: "····", else: String.slice(trimmed, -4, 4)
  end
end
