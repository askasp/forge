export const AutoScroll = {
  mounted() {
    this.autoScroll = true
    this.el.addEventListener("scroll", () => {
      const { scrollTop, scrollHeight, clientHeight } = this.el
      // If user scrolled up more than 50px from bottom, pause auto-scroll
      this.autoScroll = scrollHeight - scrollTop - clientHeight < 50
    })
  },
  updated() {
    if (this.autoScroll) {
      this.el.scrollTop = this.el.scrollHeight
    }
  }
}
