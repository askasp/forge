export const ProjectPathAutocomplete = {
  mounted() {
    this.input = this.el.querySelector("input")
    if (!this.input) return

    this.input.addEventListener("keydown", (e) => {
      const dropdown = this.el.querySelector("[data-suggestions]")
      const hasSuggestions = dropdown && dropdown.children.length > 0

      if (e.key === "ArrowDown") {
        e.preventDefault()
        this.pushEvent("navigate_suggestion", {direction: "down"})
      } else if (e.key === "ArrowUp") {
        e.preventDefault()
        this.pushEvent("navigate_suggestion", {direction: "up"})
      } else if ((e.key === "Enter" || e.key === "Tab") && hasSuggestions) {
        const selected = dropdown.querySelector("[data-selected='true']")
        if (selected) {
          e.preventDefault()
          e.stopPropagation()
          this.pushEvent("select_project", {path: selected.dataset.path})
        }
      } else if (e.key === "Escape") {
        this.pushEvent("clear_suggestions", {})
      }
    })
  }
}
