defmodule LSWeb.HumanCopyTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the house writing style on everything a person reads.

  2026-08-27: the owner found em dashes littered across the public pages and
  asked that the product never again read as machine-written. Style guidance
  in a document is forgotten by the next session; a failing test is not. This
  checks the marks that give it away, in the places customers actually see:
  page templates and the strings that go out by email.

  If you are adding copy and this test fails, do not reach for the character.
  Write the sentence the way you would say it: a comma, a colon, or two
  sentences.
  """

  @templates Path.wildcard("lib/ls_web/**/*.heex")
  @email_modules Path.wildcard("lib/ls/{alerts,feedback,engagement}.ex") ++
                   Path.wildcard("lib/ls/{ops,report}/*.ex")

  # Marks a person typing in a text editor does not produce.
  @tells %{
    "em dash (—)" => ~r/—/,
    "en dash (–)" => ~r/–/,
    "curly double quote" => ~r/[\x{201C}\x{201D}]/u,
    "ellipsis character (…)" => ~r/…/
  }

  test "no machine-typography in any page template" do
    offenders =
      for f <- @templates,
          {name, re} <- @tells,
          body = File.read!(f),
          Regex.match?(re, body),
          do: "#{f}: #{name}"

    assert offenders == [],
           "user-facing copy must read as human-written:\n  " <> Enum.join(offenders, "\n  ")
  end

  test "no machine-typography in strings that go out by email" do
    offenders =
      for f <- @email_modules,
          body = File.read!(f),
          line <- String.split(body, "\n"),
          # only quoted strings: code comments are for us, not for readers
          captured <- Regex.scan(~r/"[^"\n]*"/, line),
          s <- captured,
          Regex.match?(~r/[—–…\x{201C}\x{201D}]/u, s),
          do: "#{f}: #{String.slice(s, 0, 70)}"

    assert offenders == [],
           "email copy must read as human-written:\n  " <> Enum.join(offenders, "\n  ")
  end

  test "the guard actually catches an offending string" do
    # Proof the regexes work, so a green run means something.
    assert Regex.match?(@tells["em dash (—)"], "we scan domains — and rank them")
    refute Regex.match?(@tells["em dash (—)"], "we scan domains, and rank them")
  end
end
