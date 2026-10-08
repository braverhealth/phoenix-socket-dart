defmodule BackendWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :backend

  socket("/socket", BackendWeb.UserSocket,
    auth_token: true,
    websocket: true,
    longpoll: [
      window_ms: 1_000,
      pubsub_timeout_ms: 100
    ]
  )
end
