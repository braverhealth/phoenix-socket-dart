use Mix.Config

# The Dart E2E runner opts into a loopback server on an OS-assigned port.
config :backend, BackendWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 0],
  check_origin: false,
  server: System.get_env("PHOENIX_E2E") == "1"

config :backend, BackendWeb.ControlEndpoint, server: false

# Print only warnings and errors during test
config :logger, level: :warn
