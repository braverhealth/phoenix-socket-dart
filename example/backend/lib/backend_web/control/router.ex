defmodule BackendWeb.ControlRouter do
  use Phoenix.Router

  get "/stop", BackendWeb.Control, :stop
  get "/start", BackendWeb.Control, :start
end

defmodule BackendWeb.Control do
  @moduledoc """
  Control endpoint
  """

  use Phoenix.Controller, namespace: BackendWeb

  import Plug.Conn

  def stop(conn, _args) do
    Supervisor.terminate_child(Backend.Supervisor, BackendWeb.Supervisor)
    send_resp(conn, 200, "OK")
  end

  def start(conn, _args) do
    Supervisor.which_children(Backend.Supervisor)
    |> Enum.find(&(elem(&1, 0) == BackendWeb.Supervisor))
    |> case do
      {BackendWeb.Supervisor, :undefined, :supervisor, _rest} ->
        Supervisor.restart_child(Backend.Supervisor, BackendWeb.Supervisor)

      _ ->
        :ok
    end

    send_resp(conn, 200, "OK")
  end
end
