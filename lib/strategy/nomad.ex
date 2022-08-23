defmodule Cluster.Strategy.Nomad do
  @moduledoc """
  This clustering strategy works by querying Nomad for a service specified
  by name. It will poll for new service addresses based on the polling interval
  specified (in milliseconds).

  ## Options

  * `service_name` - The name of the Nomad service you wish to get the addresses for (required; e.g. "my-elixir-app")
  * `namespace` - The Nomad namespace to query (optional; default: "default")
  * `nomad_server_url` - The short name of the nodes you wish to connect to (required; e.g. "https://127.0.0.1:4646")
  * `poll_interval` - How often to poll in milliseconds (optional; default: 5_000)

  ## Usage

      config :libcluster,
        topologies: [
          dns_poll_example: [
            strategy: #{__MODULE__},
            config: [
              service_name: "my-elixir-app",
              nomad_server_url: "https://my-nomad-url:4646",
              namespace: "engineering",
              polling_interval: 5_000]]]
  """

  use GenServer
  import Cluster.Logger

  alias Cluster.Strategy.State
  alias Cluster.Strategy

  @default_polling_interval 5_000
  @default_namespace "default"
  @default_token ""

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init([%State{meta: nil} = state]) do
    init([%State{state | :meta => MapSet.new()}])
  end

  def init([%State{} = state]) do
    {:ok, do_poll(state)}
  end

  @impl true
  def handle_info(:timeout, state), do: handle_info(:poll, state)
  def handle_info(:poll, state), do: {:noreply, do_poll(state)}
  def handle_info(_, state), do: {:noreply, state}

  defp do_poll(
         %State{
           topology: topology,
           connect: connect,
           disconnect: disconnect,
           list_nodes: list_nodes
         } = state
       ) do
    new_nodelist = state |> get_nodes() |> MapSet.new()
    removed = MapSet.difference(state.meta, new_nodelist)

    new_nodelist =
      case Strategy.disconnect_nodes(
             topology,
             disconnect,
             list_nodes,
             MapSet.to_list(removed)
           ) do
        :ok ->
          new_nodelist

        {:error, bad_nodes} ->
          # Add back the nodes which should have been removed, but which couldn't be for some reason
          Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
            MapSet.put(acc, n)
          end)
      end

    new_nodelist =
      case Strategy.connect_nodes(
             topology,
             connect,
             list_nodes,
             MapSet.to_list(new_nodelist)
           ) do
        :ok ->
          new_nodelist

        {:error, bad_nodes} ->
          # Remove the nodes which should have been added, but couldn't be for some reason
          Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
            MapSet.delete(acc, n)
          end)
      end

    Process.send_after(self(), :poll, polling_interval(state))

    %{state | :meta => new_nodelist}
  end

  defp polling_interval(%{config: config}) do
    Keyword.get(config, :polling_interval, @default_polling_interval)
  end

  defp get_namespace(config) do
    Keyword.get(config, :namespace, @default_namespace)
  end

  defp get_token(config) do
    Keyword.get(config, :token, @default_token)
  end

  defp get_nodes(%State{config: config} = state) do
    server_url = Keyword.fetch(config, :nomad_server_url)
    service_name = Keyword.fetch(config, :service_name)
    namespace = get_namespace(config)
    token = get_token(config)

    fetch_nodes(server_url, service_name, namespace, token, state)
  end

  defp fetch_nodes(
         {:ok, server_url},
         {:ok, service_name},
         namespace,
         token,
         %State{
           topology: topology
         } = state
       )
       when server_url != "" and service_name != "" do
    debug(topology, "polling nomad for '#{service_name}' in namespace '#{namespace}'")

    headers = [{'X-Nomad-Token', '#{token}'}]
    http_options = [ssl: [verify: :verify_none], timeout: 15000]
    url = 'https://#{server_url}/v1/service/#{sevice_name}'

    case :httpc.request(:get, {url, headers}, http_options, []) do
      {:ok, {{_version, 200, _status}, _headers, body}} ->
        parse_response(service_name, Jason.decode!(body))

        Jason.decode!(body)
        |> Enum.map(fn %{Address: addr, Port: port} -> "#{service_name}@#{addr}:#{port}" end)

      {:ok, {{_version, 403, _status}, _headers, body}} ->
        %{"message" => msg} = Jason.decode!(body)
        warn(topology, "cannot query nomad (unauthorized): #{msg}")
        []

      {:ok, {{_version, code, status}, _headers, body}} ->
        warn(topology, "cannot query nomad (#{code} #{status}): #{inspect(body)}")
        []

      {:error, reason} ->
        error(topology, "request to nomad failed!: #{inspect(reason)}")
        []
    end
  end

  defp fetch_nodes(
         {:ok, invalid_server_url},
         {:ok, invalid_service_name},
         _namespace,
         _token,
         %State{
           topology: topology
         }
       ) do
    warn(
      topology,
      "nomad strategy is selected, but server_url or service_name param is invalid: #{inspect(%{nomad_server_url: invalid_server_url, service_name: invalid_service_name})}"
    )

    []
  end

  defp fetch_nodes(:error, _service_name, _namespace, _token, %State{topology: topology}) do
    warn(
      topology,
      "nomad polling strategy is selected, but nomad_server_url param missed"
    )

    []
  end

  defp fetch_nodes(_server_url, :error, _namespace, _token, %State{topology: topology}) do
    warn(
      topology,
      "nomad polling strategy is selected, but service_name param missed"
    )

    []
  end
end