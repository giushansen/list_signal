defmodule LSWeb.MagicLinkTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Security audit 2026-09-09: the login and sign-up forms had no send limit,
  so anyone could make Mailgun send unlimited mail from listsignal.com.
  """

  test "a person can ask for a link a few times, then must wait" do
    email = "person#{System.unique_integer([:positive])}@example.com"
    assert Enum.all?(1..5, fn _ -> LSWeb.MagicLink.allowed?(email) end)
    refute LSWeb.MagicLink.allowed?(email)
  end

  test "case and whitespace do not create a fresh allowance" do
    email = "Mixed#{System.unique_integer([:positive])}@Example.com"
    for _ <- 1..5, do: LSWeb.MagicLink.allowed?(email)
    refute LSWeb.MagicLink.allowed?("  " <> String.downcase(email) <> " ")
  end

  test "a missing address is never sent to" do
    refute LSWeb.MagicLink.allowed?(nil)
    refute LSWeb.MagicLink.allowed?(%{})
  end
end
