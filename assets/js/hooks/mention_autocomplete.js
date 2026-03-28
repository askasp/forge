export const MentionAutocomplete = {
  mounted() {
    this.textarea = this.el.querySelector("textarea")
    if (!this.textarea) return

    this.textarea.addEventListener("input", () => {
      const pos = this.textarea.selectionStart
      const text = this.textarea.value.substring(0, pos)

      // Find last @ that is at position 0 or preceded by space/newline
      const match = text.match(/(?:^|[\s\n])@([^\s]*)$/)
      if (match) {
        this.pushEvent("mention_search", {query: match[1]})
      } else {
        this.pushEvent("mention_clear", {})
      }
    })

    this.textarea.addEventListener("keydown", (e) => {
      const dropdown = this.el.querySelector("[data-mention-results]")
      const hasResults = dropdown && dropdown.children.length > 0

      if (e.key === "ArrowDown" && hasResults) {
        e.preventDefault()
        this.pushEvent("mention_navigate", {direction: "down"})
      } else if (e.key === "ArrowUp" && hasResults) {
        e.preventDefault()
        this.pushEvent("mention_navigate", {direction: "up"})
      } else if (e.key === "Enter" && hasResults) {
        e.preventDefault()
        this.pushEvent("mention_select", {})
      } else if (e.key === "Tab" && hasResults) {
        e.preventDefault()
        this.pushEvent("mention_select", {})
      } else if (e.key === "Escape" && hasResults) {
        e.preventDefault()
        this.pushEvent("mention_clear", {})
      }
    })

    this.handleEvent("mention_selected", ({text}) => {
      const pos = this.textarea.selectionStart
      const value = this.textarea.value
      const before = value.substring(0, pos)

      // Find the @query to replace
      const match = before.match(/(?:^|[\s\n])@([^\s]*)$/)
      if (match) {
        const atStart = before.lastIndexOf("@" + match[1])
        const after = value.substring(pos)
        const replacement = text + " "
        this.textarea.value = before.substring(0, atStart) + replacement + after
        const newPos = atStart + replacement.length
        this.textarea.selectionStart = newPos
        this.textarea.selectionEnd = newPos
        this.textarea.focus()
        // Trigger input event so LiveView picks up the value change
        this.textarea.dispatchEvent(new Event("input", {bubbles: true}))
      }
    })
  }
}
