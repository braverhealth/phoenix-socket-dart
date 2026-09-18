defmodule BackendWeb.AuditChannel do
  @moduledoc false
  use Phoenix.Channel

  def join("audit:" <> _topic, params, socket) do
    Process.sleep(Map.get(params, "join_delay_ms", 0))

    if Map.get(params, "reject", false) do
      {:error, %{reason: "requested rejection"}}
    else
      {:ok, assign(socket, :observed, 0)}
    end
  end

  def handle_in("echo", payload, socket) do
    {:reply, {:ok, payload}, socket}
  end

  def handle_in("no_reply", payload, socket) do
    push(socket, "observed", payload)
    {:noreply, assign(socket, :observed, socket.assigns.observed + 1)}
  end

  def handle_in("stats", _payload, socket) do
    {:reply, {:ok, %{observed: socket.assigns.observed}}, socket}
  end

  def handle_in("close_pending", _payload, socket) do
    {:stop, :normal, socket}
  end

  def handle_in("echo_event", %{"event" => event, "payload" => payload}, socket) do
    push(socket, event, payload)
    {:reply, {:ok, %{}}, socket}
  end

  def handle_in("disconnect", _payload, socket) do
    BackendWeb.Endpoint.broadcast!(socket.id, "disconnect", %{})
    {:noreply, socket}
  end
end
