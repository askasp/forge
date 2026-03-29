export const AutoScroll = {
  mounted() {
    this.autoScroll = true
    this.lastScrollHeight = this.el.scrollHeight
    this.el.addEventListener("scroll", () => {
      const { scrollTop, scrollHeight, clientHeight } = this.el
      // If user scrolled up more than 50px from bottom, pause auto-scroll
      this.autoScroll = scrollHeight - scrollTop - clientHeight < 50
    })
  },
  updated() {
    const newScrollHeight = this.el.scrollHeight
    // Only auto-scroll when content actually grew (new lines/cards added),
    // not on re-renders of existing content (task status changes, etc.)
    if (this.autoScroll && newScrollHeight > this.lastScrollHeight) {
      this.el.scrollTop = this.el.scrollHeight
    }
    this.lastScrollHeight = newScrollHeight
  }
}
