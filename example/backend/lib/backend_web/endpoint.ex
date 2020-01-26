defmodule BackendWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :backend

  socket("/socket", BackendWeb.UserSocket,
    websocket: true,
    longpoll: false
  )
end
