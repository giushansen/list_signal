defmodule LS.ApiKeys.Vault do
  @moduledoc """
  Reversible encryption for an API key's plaintext, so Settings can show a
  key again after it was created.

  Why (2026-10-26): keys were hash-only, the GitHub model, and the owner
  could not read his own key back from Settings. For a product whose keys
  get pasted into claude.ai, Smithery and a CRM by one or two people, a key
  you cannot re-read is a support ticket, not a security property. The
  hash in `api_keys.key_hash` stays the only thing the auth path reads;
  the ciphertext here is read by one place, the owner's Settings page,
  which already sits behind sudo mode.

  AES-256-GCM. The key is derived from the endpoint's `secret_key_base`
  with a fixed salt, the same pattern `Phoenix.Token` uses, so there is no
  new secret to provision. Rotating `SECRET_KEY_BASE` makes older
  ciphertexts unreadable; `decrypt/1` then returns `:error` and Settings
  tells the user to rotate the key. Stored layout: iv (12) <> tag (16) <>
  ciphertext.
  """

  @salt "api-key-reveal"
  @aad "ls-api-key"

  @doc "Encrypt a plaintext key for storage."
  @spec encrypt(binary()) :: binary()
  def encrypt(plaintext) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(12)
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plaintext, @aad, true)
    iv <> tag <> ct
  end

  @doc """
  Decrypt a stored blob. `:error` on a tampered blob, a blob written under a
  different `secret_key_base`, or anything that is not a blob at all.
  """
  @spec decrypt(term()) :: {:ok, binary()} | :error
  def decrypt(<<iv::binary-size(12), tag::binary-size(16), ct::binary>>) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ct, @aad, tag, false) do
      :error -> :error
      plain when is_binary(plain) -> {:ok, plain}
    end
  end

  def decrypt(_), do: :error

  defp key do
    secret = Application.fetch_env!(:ls, LSWeb.Endpoint)[:secret_key_base]
    Plug.Crypto.KeyGenerator.generate(secret, @salt, length: 32, cache: Plug.Crypto.Keys)
  end
end
