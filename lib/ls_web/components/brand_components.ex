defmodule LSWeb.BrandComponents do
  @moduledoc """
  The ListSignal mark and the ways it is allowed to appear.

  "Live list": three horizontal lines of equal length and stroke, the middle
  one carrying a heartbeat. Three records, one live signal. The path below is
  the logo; it is frozen. Every raster and SVG under `priv/static/images/brand/`
  and every favicon is generated from the same path by
  `docs/brand/gen_brand_assets.py`, so the inline mark, the tab icon and the
  share card can never disagree.

  Three components, imported into every template through `LSWeb.html_helpers/0`:

    * `logo_mark/1`, the bare mark, inline SVG, coloured by `currentColor`
    * `logo_tile/1`, the mark on the rounded accent square
    * `logo_lockup/1`, the tile beside the "ListSignal" wordmark, as a link

  The full rules (colourways, clear space, minimum sizes, the don'ts) are in
  `docs/brand/README.md`. Emails deliberately carry no logo, see
  `test/ls/engagement_test.exs`.
  """
  use Phoenix.Component

  # 64-unit grid, stroke 7, round caps and joins. Do not edit.
  @mark_path "M10 11H54 M10 32H23L28 23L36 41L41 32H54 M10 53H54"

  @doc "The frozen path of the mark, exposed so tests can pin it."
  def mark_path, do: @mark_path

  @doc """
  The bare mark as inline SVG. Takes the surrounding text colour and costs no
  request. Decorative by default (`aria-hidden`); pass `label` to make it an
  image with an accessible name.
  """
  attr :size, :integer, default: 24, doc: "width and height in px"
  attr :class, :string, default: nil
  attr :label, :string, default: nil, doc: "accessible name; nil means decorative"

  def logo_mark(assigns) do
    assigns = assign(assigns, :path, @mark_path)

    ~H"""
    <svg
      viewBox="0 0 64 64"
      width={@size}
      height={@size}
      fill="none"
      stroke="currentColor"
      stroke-width="7"
      stroke-linecap="round"
      stroke-linejoin="round"
      class={@class}
      role={@label && "img"}
      aria-hidden={if @label, do: nil, else: "true"}
    >
      <title :if={@label}>{@label}</title>
      <path d={@path} />
    </svg>
    """
  end

  @doc """
  The mark on the rounded accent square, white on green. The default size is
  the public navbar's 30px box; `size` scales box and mark together (the mark
  is 0.66 of the box, the same ratio the generated tiles use). No gradient:
  the old letter box had one, nothing in the brand does.
  """
  attr :size, :integer, default: 30, doc: "box side in px"
  attr :class, :string, default: nil

  def logo_tile(assigns) do
    assigns =
      assigns
      |> assign(:mark, round(assigns.size * 0.66))
      |> assign(:radius, if(assigns.size >= 24, do: "rounded-lg", else: "rounded"))

    ~H"""
    <span
      class={["flex flex-shrink-0 items-center justify-center bg-accent text-white", @radius, @class]}
      style={"height:#{@size}px;width:#{@size}px"}
    >
      <.logo_mark size={@mark} />
    </span>
    """
  end

  @doc """
  Tile plus the wordmark, as a link. The wordmark is always the display font,
  bold, tight tracking; `text_class` sets its size (the navbar's 21px by
  default) and `href` where the link goes.
  """
  attr :href, :string, default: "/"
  attr :text_class, :string, default: "text-[21px]"
  attr :class, :string, default: nil

  def logo_lockup(assigns) do
    ~H"""
    <a
      href={@href}
      class={[
        "inline-flex items-center gap-2 font-display font-bold tracking-tight text-white",
        @text_class,
        @class
      ]}
    >
      <.logo_tile /> ListSignal
    </a>
    """
  end
end
