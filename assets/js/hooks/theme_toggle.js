export const ThemeToggle = {
  mounted() {
    this.el.addEventListener("click", (e) => {
      e.preventDefault()
      e.stopPropagation()
      const html = document.documentElement
      const current = html.getAttribute("data-theme")
      const next = current === "dark" ? "light" : "dark"
      html.setAttribute("data-theme", next)
      localStorage.setItem("phx:theme", next)
      console.log("[Forge] Theme toggled:", current, "→", next)
    })
  }
}
