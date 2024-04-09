defmodule BackendWeb.ControlEndpoint do
  use Phoenix.Endpoint, otp_app: :backend

  plug(BackendWeb.ControlRouter)
end
