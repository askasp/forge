export const KeyboardShortcuts = {
  mounted() {
    this.handleKeyDown = (e) => {
      // Don't fire when typing in inputs/textareas
      const tag = e.target.tagName
      if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return

      if ((e.metaKey || e.ctrlKey) && e.key === "k") {
        e.preventDefault()
        this.pushEvent("toggle_ask", {})
      } else if ((e.metaKey || e.ctrlKey) && e.key === "b") {
        e.preventDefault()
        this.pushEvent("toggle_sidebar", {})
      } else if ((e.metaKey || e.ctrlKey) && e.key === "n") {
        e.preventDefault()
        this.pushEvent("new_session", {})
      } else if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
        e.preventDefault()
        this.pushEvent("continue", {})
      } else if (e.key === "Escape") {
        e.preventDefault()
        this.pushEvent("pause", {})
      } else if ((e.metaKey || e.ctrlKey) && e.key === ".") {
        e.preventDefault()
        this.pushEvent("skip", {})
      } else if ((e.metaKey || e.ctrlKey) && e.key === "Backspace") {
        e.preventDefault()
        if (confirm("Kill this session and delete its worktree?")) {
          this.pushEvent("kill_session", {})
        }
      } else if (e.key === "?" && !e.metaKey && !e.ctrlKey) {
        e.preventDefault()
        this.pushEvent("toggle_shortcuts", {})
      }
    }
    document.addEventListener("keydown", this.handleKeyDown)
  },
  destroyed() {
    document.removeEventListener("keydown", this.handleKeyDown)
  }
}
