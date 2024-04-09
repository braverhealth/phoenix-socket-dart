defmodule BackendWeb.Channel1 do
  @moduledoc false
  use Phoenix.Channel

  def join("channel1", _message, socket) do
    {:ok, socket}
  end

  def join("channel1:" <> _name, %{"password" => "deadbeef"}, socket) do
    {:ok, socket}
  end

  def join("channel1:" <> _name, %{"password" => _}, _socket) do
    {:error, "wrong password"}
  end

  def handle_in("hello!", %{"foo" => name}, socket) do
    {:reply, {:ok, %{name: name}}, socket}
  end
end
