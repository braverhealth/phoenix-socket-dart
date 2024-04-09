defmodule BackendWeb.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts ++ [name: Backend.Supervisor])
  end

  def init(_) do
    children = [
      {Phoenix.PubSub, [name: Backend.PubSub, adapter: Phoenix.PubSub.PG2]},
      BackendWeb.Endpoint,
      BackendWeb.Presence
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def child_spec(init_arg) do
    %{
      id: BackendWeb.Supervisor,
      start: {BackendWeb.Supervisor, :start_link, [init_arg]},
      type: :supervisor
    }
  end
end
