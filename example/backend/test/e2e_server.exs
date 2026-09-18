port = :ranch.get_port(BackendWeb.Endpoint.HTTP)
IO.puts("PHOENIX_E2E_PORT=#{port}")

# Closing the runner's stdin also shuts down the exact BEAM instance it owns.
case IO.read(:stdio, :line) do
  _ -> System.stop(0)
end
