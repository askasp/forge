export const Notifications = {
  mounted() {
    // Request permission on first mount
    if ("Notification" in window && Notification.permission === "default") {
      Notification.requestPermission()
    }

    this.handleEvent("notify", ({ title, body }) => {
      // Only notify if tab is not focused
      if (document.hidden && "Notification" in window && Notification.permission === "granted") {
        new Notification(title, { body, icon: "/favicon.ico" })
      }
    })
  }
}
