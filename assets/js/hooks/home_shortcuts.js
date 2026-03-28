export const HomeShortcuts = {
  mounted() {
    this.handleKeyDown = (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
        e.preventDefault()
        const form = document.querySelector('form[phx-submit="start_session"]')
        if (form) form.requestSubmit()
      }
    }
    document.addEventListener("keydown", this.handleKeyDown)
  },
  destroyed() {
    document.removeEventListener("keydown", this.handleKeyDown)
  }
}
