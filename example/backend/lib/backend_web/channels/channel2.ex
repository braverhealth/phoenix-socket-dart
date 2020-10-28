defmodule BackendWeb.Channel2 do
  @moduledoc false
  use Phoenix.Channel

  def join("channel2", _message, socket) do
    :timer.send_interval(100, :send)
    {:ok, socket}
  end

  def handle_info(:send, socket) do
    push(socket, "ping", %{})
    {:noreply, socket}
  end
end
