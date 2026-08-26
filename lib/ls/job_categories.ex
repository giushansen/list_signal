defmodule LS.JobCategories do
  @moduledoc """
  Job titles → functional categories, and the one-line hiring snapshot
  (`Engineering:12|Sales:4 (18 open)`) stored in
  `businesses.positions_overview`.

  The snapshot is the product-facing shape of hiring data: what functions a
  company is building out right now. It is computed wherever jobs are seen —
  the worker Jobs enricher and the board sync — from the raw `biz_career`
  titles, so the raw rows stay the source of truth and the summary can be
  recomputed when the taxonomy changes.

  First matching keyword wins, scanning categories in a fixed order (an
  "Engineering Manager" is Engineering, not Management — buyers care about
  the function being hired, seniority is noise at this grain).
  """

  @categories [
    {"Engineering",
     ~w(engineer developer devops sre software backend frontend fullstack full-stack
        architect qa sysadmin infrastructure security ios android mobile embedded firmware)},
    {"Data", ~w(data analyst analytics scientist ml machine-learning ai bi statistician)},
    {"Product", ~w(product owner pm)},
    {"Design", ~w(designer design ux ui graphic creative brand-designer)},
    {"Sales", ~w(sales account-executive business-development bdr sdr commercial partnerships revenue)},
    {"Marketing", ~w(marketing growth content seo sem communications pr community social-media)},
    {"Support", ~w(support customer-success customer-service success helpdesk implementation onboarding)},
    {"HR", ~w(recruiter recruiting talent people human-resources hr)},
    {"Finance", ~w(finance accountant accounting controller payroll treasury fp&a auditor)},
    {"Legal", ~w(legal counsel compliance paralegal privacy)},
    {"Operations",
     ~w(operations logistics supply-chain procurement warehouse office-manager administrative admin assistant)},
    {"Medical", ~w(nurse physician clinical medical therapist pharmacist dental veterinary caregiver)}
  ]

  @doc "The functional category for one job title. Unknown titles are \"Other\"."
  @spec categorize(String.t() | nil) :: String.t()
  def categorize(title) when is_binary(title) do
    d = title |> String.downcase() |> String.replace(~r/[^a-z&+-]+/, "-")
    tokens = String.split(d, "-", trim: true)

    Enum.find_value(@categories, "Other", fn {cat, keywords} ->
      # Single-word keywords match whole tokens only ("pm" must not match
      # inside "development"); hyphenated ones match the joined phrase.
      if Enum.any?(keywords, fn kw ->
           if String.contains?(kw, "-"), do: String.contains?(d, kw), else: kw in tokens
         end),
         do: cat
    end)
  end

  def categorize(_), do: "Other"

  @doc """
  The hiring snapshot for a list of job titles:
  `"Engineering:12|Sales:4|Other:2 (18 open)"` — top 6 categories, largest
  first. Empty list → empty string (no jobs is "nothing to say", not "0").
  """
  @spec summarize([String.t() | nil]) :: String.t()
  def summarize([]), do: ""

  def summarize(titles) when is_list(titles) do
    top =
      titles
      |> Enum.map(&categorize/1)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {k, n} -> {-n, k == "Other", k} end)
      |> Enum.take(6)
      |> Enum.map_join("|", fn {k, n} -> "#{k}:#{n}" end)

    "#{top} (#{length(titles)} open)"
  end
end
