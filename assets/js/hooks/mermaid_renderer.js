/**
 * MermaidRenderer hook — lazy-loads mermaid.js and renders
 * ```mermaid code blocks into SVG diagrams.
 */
const MermaidRenderer = {
  mounted() {
    this.renderMermaid()
  },
  updated() {
    this.renderMermaid()
  },
  renderMermaid() {
    const blocks = this.el.querySelectorAll(
      "pre > code.language-mermaid, code.language-mermaid"
    )
    if (blocks.length === 0) return

    if (!window.mermaid) {
      const script = document.createElement("script")
      script.src =
        "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"
      script.onload = () => {
        window.mermaid.initialize({ startOnLoad: false, theme: "neutral" })
        this.doRender(blocks)
      }
      document.head.appendChild(script)
    } else {
      this.doRender(blocks)
    }
  },
  doRender(blocks) {
    blocks.forEach((block) => {
      const pre = block.closest("pre") || block
      const div = document.createElement("div")
      div.className = "mermaid"
      div.textContent = block.textContent
      pre.replaceWith(div)
    })
    // Let mermaid process all new .mermaid divs
    try {
      window.mermaid.run({ querySelector: ".mermaid" })
    } catch (e) {
      console.warn("Mermaid render failed:", e)
    }
  },
}

export default MermaidRenderer
