defmodule BackendWeb.Channel3 do
  @moduledoc false
  use Phoenix.Channel

  def join("channel3", _message, socket) do
    {:ok, socket}
  end

  def handle_in("ping", payload, socket) do
    BackendWeb.Endpoint.broadcast!("channel3", "pong", payload)
    {:noreply, socket}
  end
end
