# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
use Mix.Config

# Configures the endpoint
config :backend, BackendWeb.Endpoint,
  url: [host: "localhost"],
  secret_key_base: "LkOAHmBjZB9uu1CTg3Z28ZnvysCl8LhqRGBxwq32eIR7P10XuMSmLIft/QgG1b8D",
  render_errors: [view: BackendWeb.ErrorView, accepts: ~w(html json)],
  pubsub_server: Backend.PubSub

config :backend, BackendWeb.ControlEndpoint,
  url: [host: "localhost"],
  secret_key_base: "LkOAHmBjZB9uu1CTg3Z28ZnvysCl8LhqRGBxwq32eIR7P10XuMSmLIft/QgG1b8D",
  render_errors: [view: BackendWeb.ErrorView, accepts: ~w(html json)]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env()}.exs"
