defmodule BackendWeb.UserSocket do
  use Phoenix.Socket

  ## Channels
  channel("channel1", BackendWeb.Channel1)
  channel("channel1:*", BackendWeb.Channel1)
  channel("channel2", BackendWeb.Channel2)
  channel("channel3", BackendWeb.Channel3)
  channel("presence:lobby", BackendWeb.PresenceChannel)


  # Socket params are passed from the client and can
  # be used to verify and authenticate a user. After
  # verification, you can put default assigns into
  # the socket that will be set for all channels, ie
  #
  #     {:ok, assign(socket, :user_id, verified_user_id)}
  #
  # To deny connection, return `:error`.
  #
  # See `Phoenix.Token` documentation for examples in
  # performing token verification on connect.
  def connect(%{"user_id" => user_id}, socket, _connect_info) do
    {:ok, assign(socket, :user_id, user_id)}
  end

  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  # Socket id's are topics that allow you to identify all sockets for a given user:
  #
  #     def id(socket), do: "user_socket:#{socket.assigns.user_id}"
  #
  # Would allow you to broadcast a "disconnect" event and terminate
  # all active sockets and channels for a given user:
  #
  #     BackendWeb.Endpoint.broadcast("user_socket:#{user.id}", "disconnect", %{})
  #
  # Returning `nil` makes this socket anonymous.
  def id(socket) do
    if Map.has_key?(socket.assigns, :user_id) do
      "user_socket:#{socket.assigns.user_id}"
    else
      nil
    end
  end
end
