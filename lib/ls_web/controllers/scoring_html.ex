defmodule LSWeb.ScoringHTML do
  @moduledoc "Templates for the public scoring-methodology pages."
  use LSWeb, :html

  embed_templates "scoring_html/*"

  @doc """
  Shared page shell: title, standfirst, then the caller's content.

  Every scoring page uses it so they read as one family rather than four
  one-off landing pages.
  """
  attr :title, :string, required: true
  attr :lede, :string, required: true
  attr :eyebrow, :string, default: "Methodology"
  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <main class="pt-[140px] pb-20"><div class="mx-auto max-w-[880px] px-6">
      <div class="mb-12">
        <span class="inline-flex px-2.5 py-1 rounded-md text-[10px] uppercase tracking-[1.5px] bg-accent/10 text-accent font-semibold mb-5">
          {@eyebrow}
        </span>
        <h1 class="font-display text-[clamp(30px,4vw,44px)] font-bold tracking-tight leading-[1.12] mb-4">{@title}</h1>
        <p class="text-lg text-white/60 leading-relaxed">{@lede}</p>
      </div>
      {render_slot(@inner_block)}
      <div class="mt-14 pt-10 border-t border-white/[0.07]">
        <p class="text-sm text-white/40 mb-4">Other scoring methodology</p>
        <div class="flex flex-wrap gap-3">
          <%= for {_k, path, label} <- LSWeb.ScoringController.slugs() do %>
            <a href={path} class="text-sm px-4 py-2 rounded-lg bg-white/[0.03] border border-white/[0.07] text-white/70 hover:text-white hover:border-white/20 transition-colors">{label}</a>
          <% end %>
        </div>
      </div>
      <div class="mt-12 text-center">
        <a href="/signup" class="inline-flex items-center gap-2 rounded-xl bg-accent px-8 py-4 font-display text-[15px] font-semibold text-white shadow-[0_8px_28px_rgba(16,185,129,0.25)] hover:bg-accent-hover">Start free — no credit card required</a>
      </div>
    </div></main>
    """
  end

  @doc "A weighted-check row, used by the score-breakdown tables."
  attr :name, :string, required: true
  attr :weight, :string, required: true
  attr :why, :string, required: true

  def check(assigns) do
    ~H"""
    <tr class="border-b border-white/[0.05]">
      <td class="py-3 pr-4 font-medium text-white/85">{@name}</td>
      <td class="py-3 pr-4 text-accent font-mono text-sm whitespace-nowrap">{@weight}</td>
      <td class="py-3 text-sm text-white/55 leading-relaxed">{@why}</td>
    </tr>
    """
  end

  @doc "Callout box for the 'why this matters to you' sections."
  attr :title, :string, required: true
  attr :tone, :string, default: "accent"
  slot :inner_block, required: true

  def aside(assigns) do
    ~H"""
    <div class={"p-6 rounded-[18px] border mb-6 " <> case @tone do
      "amber" -> "bg-amber-500/[0.06] border-amber-500/20"
      "blue"  -> "bg-blue-500/[0.06] border-blue-500/20"
      _       -> "bg-accent/[0.06] border-accent/20"
    end}>
      <h3 class="font-display text-[15px] font-semibold mb-2">{@title}</h3>
      <div class="text-sm text-white/65 leading-relaxed">{render_slot(@inner_block)}</div>
    </div>
    """
  end
end
