defmodule LS.ApiKeysRevealTest do
  @moduledoc """
  Keys can be shown again (2026-10-26). Before this, a key was hash-only
  and the owner could not read his own key back from Settings. The hash is
  still the only thing auth reads; these tests pin that the reversible copy
  round-trips, that it refuses tampering and foreign ciphertexts, that a
  key without one degrades to `:unavailable` rather than crashing the page,
  and that backfilling a legacy key verifies the plaintext against the
  hash first.
  """
  use LSWeb.ConnCase, async: false

  alias LS.ApiKeys
  alias LS.ApiKeys.Vault

  setup do
    %{user: LS.AccountsFixtures.user_fixture()}
  end

  test "a freshly created key can be shown again, and it is the same key", %{user: user} do
    {:ok, plaintext, key} = ApiKeys.create_key(user, "claude-web")
    assert ApiKeys.reveal(key) == {:ok, plaintext}
  end

  test "revealing never changes what authenticates", %{conn: conn, user: user} do
    {:ok, _, key} = ApiKeys.create_key(user, "x")
    {:ok, plain} = ApiKeys.reveal(key)

    conn = conn |> put_req_header("authorization", "Bearer #{plain}") |> get(~p"/api/v1/stats")
    assert conn.status == 200
  end

  test "a key without a stored plaintext is unavailable, not an error", %{user: user} do
    {:ok, _, key} = ApiKeys.create_key(user, "legacy")
    legacy = %{key | encrypted_key: nil}
    assert ApiKeys.reveal(legacy) == :unavailable
  end

  test "a tampered or foreign blob is unavailable", %{user: user} do
    {:ok, _, key} = ApiKeys.create_key(user, "t")
    <<first, rest::binary>> = key.encrypted_key
    flipped = <<Bitwise.bxor(first, 1), rest::binary>>

    assert ApiKeys.reveal(%{key | encrypted_key: flipped}) == :unavailable
    assert ApiKeys.reveal(%{key | encrypted_key: "not a blob"}) == :unavailable
    assert ApiKeys.reveal(%{key | encrypted_key: <<>>}) == :unavailable
  end

  test "backfill refuses a plaintext that does not match the hash", %{user: user} do
    {:ok, plaintext, key} = ApiKeys.create_key(user, "old")
    stripped = %{key | encrypted_key: nil}

    assert {:error, :mismatch} = ApiKeys.backfill_plaintext(stripped, "ls_wrong")
    assert {:ok, filled} = ApiKeys.backfill_plaintext(stripped, plaintext)
    assert ApiKeys.reveal(filled) == {:ok, plaintext}
  end

  test "the vault round-trips hostile inputs" do
    for input <- ["", "a", String.duplicate("k", 10_000), "clé 密钥 🔑", <<0, 1, 2, 255>>] do
      assert Vault.decrypt(Vault.encrypt(input)) == {:ok, input}
    end
  end

  test "two encryptions of the same key differ (fresh iv), both decrypt" do
    a = Vault.encrypt("ls_same")
    b = Vault.encrypt("ls_same")
    assert a != b
    assert Vault.decrypt(a) == {:ok, "ls_same"}
    assert Vault.decrypt(b) == {:ok, "ls_same"}
  end
end
