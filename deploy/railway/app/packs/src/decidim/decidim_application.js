// This file is compiled inside Decidim core pack. Code can be added here and will be executed
// as part of that pack

// Load images
require.context("../../images", true)

// Demo login on the dev instance only, like try.decidim.org: prefill the
// seeded admin credentials (also shown in the omnipresent banner).
const DEMO_LOGIN_HOSTS = ["decidim-dev.vocdoni.net"]

document.addEventListener("DOMContentLoaded", () => {
  if (!DEMO_LOGIN_HOSTS.includes(window.location.hostname)) {
    return
  }
  const email = document.getElementById("session_user_email")
  const password = document.getElementById("session_user_password")
  if (email && password) {
    email.value = "admin@example.org"
    password.value = "decidim123456789"
  }
})
