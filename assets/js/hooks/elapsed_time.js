export const ElapsedTime = {
  mounted() {
    this.startTimer()
  },
  updated() {
    this.startTimer()
  },
  destroyed() {
    if (this.interval) clearInterval(this.interval)
  },
  startTimer() {
    if (this.interval) clearInterval(this.interval)
    const startedAt = this.el.dataset.startedAt
    if (!startedAt) {
      this.el.textContent = ""
      return
    }
    const start = new Date(startedAt)
    const update = () => {
      const seconds = Math.floor((Date.now() - start.getTime()) / 1000)
      const minutes = Math.floor(seconds / 60)
      const secs = seconds % 60
      this.el.textContent = minutes > 0 ? ` \u2014 ${minutes}m ${secs}s` : ` \u2014 ${secs}s`
    }
    update()
    this.interval = setInterval(update, 1000)
  }
}
