import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import AutoClearFlashHook from "./clear_flash_hook"

let Hooks = {}
Hooks.AutoClearFlash = AutoClearFlashHook

const STORAGE_KEY = "ls_explorer_col_widths"

// Resizable table columns — persists widths to localStorage
Hooks.ResizableTable = {
  mounted() {
    this.applyWidths()
    this.attachHandles()
  },
  updated() {
    this.attachHandles()
  },
  applyWidths() {
    const saved = localStorage.getItem(STORAGE_KEY)
    if (!saved) return
    try {
      const widths = JSON.parse(saved)
      const cols = this.el.querySelectorAll("colgroup col")
      cols.forEach(col => {
        const key = col.dataset.col
        if (key && widths[key]) {
          col.style.width = widths[key] + "px"
        }
      })
    } catch(_) {}
  },
  saveWidths() {
    const cols = this.el.querySelectorAll("colgroup col")
    const widths = {}
    cols.forEach(col => {
      const key = col.dataset.col
      if (key) widths[key] = col.offsetWidth || parseInt(col.style.width) || null
    })
    localStorage.setItem(STORAGE_KEY, JSON.stringify(widths))
  },
  attachHandles() {
    // Remove existing handles to avoid duplicates
    this.el.querySelectorAll(".col-resize-handle").forEach(h => {
      if (h._listener) h.removeEventListener("mousedown", h._listener)
    })

    const handles = this.el.querySelectorAll(".col-resize-handle")
    handles.forEach(handle => {
      const listener = (e) => {
        e.preventDefault()
        e.stopPropagation()
        const th = handle.closest("th")
        if (!th) return
        const colIndex = Array.from(th.parentElement.children).indexOf(th)
        const col = this.el.querySelectorAll("colgroup col")[colIndex]
        if (!col) return

        const startX = e.clientX
        const startW = th.offsetWidth

        const onMove = (e2) => {
          const diff = e2.clientX - startX
          const newW = Math.max(40, startW + diff)
          col.style.width = newW + "px"
        }
        const onUp = () => {
          document.removeEventListener("mousemove", onMove)
          document.removeEventListener("mouseup", onUp)
          document.body.style.cursor = ""
          document.body.style.userSelect = ""
          this.saveWidths()
        }
        document.body.style.cursor = "col-resize"
        document.body.style.userSelect = "none"
        document.addEventListener("mousemove", onMove)
        document.addEventListener("mouseup", onUp)
      }
      handle._listener = listener
      handle.addEventListener("mousedown", listener)
    })
  }
}

// Client-side dropdown option filtering. Typing in a filter's search box only shows/hides
// the already-rendered options (zero backend round-trips). The backend is queried only when
// an option is actually selected. Hook lives on the dropdown panel so it survives the
// option re-render that follows a selection (re-applying the active filter in updated()).
Hooks.DropdownFilter = {
  mounted() {
    this.onInput = (e) => { if (e.target.matches("input")) this.filter() }
    this.el.addEventListener("input", this.onInput)
    const input = this.el.querySelector("input")
    if (input) requestAnimationFrame(() => input.focus())
  },
  updated() { this.filter() },
  destroyed() { this.el.removeEventListener("input", this.onInput) },
  filter() {
    const input = this.el.querySelector("input")
    const q = input ? input.value.trim().toLowerCase() : ""
    let visible = 0
    this.el.querySelectorAll(".dropdown-option").forEach(opt => {
      const show = q === "" || this.match(opt.getAttribute("data-search") || "", q)
      opt.classList.toggle("hidden", !show)
      if (show) visible++
    })
    const noRes = this.el.querySelector(".dropdown-no-results")
    if (noRes) noRes.classList.toggle("hidden", visible !== 0)
  },
  // Fuzzy: exact substring, else in-order subsequence so "sng" still matches "singapore".
  match(hay, q) {
    if (hay.indexOf(q) !== -1) return true
    let i = 0
    for (let c = 0; c < hay.length && i < q.length; c++) {
      if (hay[c] === q[i]) i++
    }
    return i === q.length
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

liveSocket.connect()
window.liveSocket = liveSocket
