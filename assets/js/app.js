import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

let Hooks = {}

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

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

liveSocket.connect()
window.liveSocket = liveSocket
