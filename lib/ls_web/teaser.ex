defmodule LSWeb.Teaser do
  @moduledoc """
  Fake-but-plausible placeholder data for blurred teasers on public pages.

  The rule these helpers enforce: **real data never reaches the DOM behind a
  blur** — a blur is one devtools click from removed, so what sits under it
  must be worthless. Fakes are deterministic per domain (stable across
  renders, so pages stay cacheable) and drawn from fixed word lists that
  cannot collide with real extracted data by construction: fake emails use
  local parts like `contact-x7`, fake subdomains use a `-x` suffix.
  """

  @email_locals ~w(contact team hello sales info office support admin)
  @sub_words ~w(portal mail app secure api shop admin dev staging cdn docs my)

  @doc "N fake blurred-placeholder emails for a domain. Never real extracted emails."
  def fake_emails(domain, n) when n > 0 do
    for i <- 1..min(n, 3) do
      local = Enum.at(@email_locals, :erlang.phash2({domain, :em, i}, length(@email_locals)))
      suffix = :erlang.phash2({domain, :es, i}, 90) + 10
      "#{local}-x#{suffix}@#{domain}"
    end
  end

  def fake_emails(_domain, _n), do: []

  @doc "N fake blurred-placeholder subdomains. The `-x` suffix guarantees they are not real."
  def fake_subdomains(domain, n) when n > 0 do
    for i <- 1..min(n, 6) do
      word = Enum.at(@sub_words, :erlang.phash2({domain, :sd, i}, length(@sub_words)))
      "#{word}-x#{:erlang.phash2({domain, :sx, i}, 9)}.#{domain}"
    end
  end

  def fake_subdomains(_domain, _n), do: []

  @tech_words ~w(Analytics-X CDN-X Widget-X Pixel-X Chat-X Forms-X Search-X Vault-X)

  @doc "N fake blurred-placeholder tech names. The -X suffix marks them fake."
  def fake_techs(domain, n) when n > 0 do
    for i <- 1..min(n, 8) do
      Enum.at(@tech_words, :erlang.phash2({domain, :tk, i}, length(@tech_words))) <>
        Integer.to_string(:erlang.phash2({domain, :tv, i}, 9))
    end
  end

  def fake_techs(_domain, _n), do: []
end
