defmodule ApiWeb.RoomChannel do
  use Phoenix.Channel

  def join("room:" <> _room_name, _message, socket) do
    socket = assign(socket, sum: 0)
    {:ok, socket}
  end

  def join("room:private:" <> _private_room_id, _params, _socket) do
    {:error, %{reason: "unauthorized"}}
  end

  def handle_in("sum", %{"times" => times}, socket) do
    more = socket.assigns.sum + times
    socket = assign(socket, :sum, more)
    broadcast!(socket, "sum", %{times: more})
    {:noreply, socket}
  end
end
