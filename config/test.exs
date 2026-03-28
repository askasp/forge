import Config

# Configure your database
config :forge, Forge.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "forge_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :forge, ForgeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "BJ+2NQVgOlF9PenNf+++OgPFP5+9ZlheqB2to8fxz2fxyfbChJqlZNxKfpn8uj/Q",
  server: false

# In test we don't send emails
config :forge, Forge.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
