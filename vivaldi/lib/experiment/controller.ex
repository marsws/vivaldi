defmodule Vivaldi.Experiment.Controller do

@moduledoc """
* Broadcasts configuration parameters to all peers, and kicks off experiment.

## Note

Vivaldi is a purely decentralized protocol, and doesn't require a central agent. 
This module exists purely to accelerate debugging
"""

  require Logger

  alias Vivaldi.Peer.{Config, ExperimentCoordinator}
  alias Vivaldi.Experiment.Logcentral

  def start(name, cookie, peer_names, session_id \\ 1) do
    up(name, cookie, session_id)
    peer_tuples = Enum.map(peer_names, fn name ->
      [node_id, ip_addr] = String.split(name, "@")
      {:"#{node_id}", :"#{node_id}@#{ip_addr}"}
    end)
    connect(peer_tuples)
    run(peer_tuples, [session_id: session_id])
  end

  def up(name, cookie, session_id \\ 1) do
    {:ok, _} = Node.start name
    Node.set_cookie cookie

    # An error is thrown if we connect to peers immediately. So sleep for a short duration.
    :timer.sleep(1000)
    {:ok, _} = Logcentral.start_link(log_path(session_id))
  end

  def visualize(session_id \\ 1) do
    src = log_path(session_id)
    dst = Path.absname("visualization/public/my_events.json", "./../")
    Logcentral.to_json(src, dst)
  end


  @doc """
  Run the following sequence of commands to kickoff the Vivaldi algorithm on each peer.
  1. Configure peers
  2. Ensure peers are ready. 
  3. Instruct peers to begin pinging each other
  """
  def run(peers, common_config) do
    # TODO: This seems like a classic use case for railway-oriented programming. 
    # http://fsharpforfunandprofit.com/rop/ Learn how to implement it.
    # The problem is my individual steps are currently not composable...
    # The below pipeline should just work for both happy channel and the error channel.

    # peers
    # |> connect()
    # |> get_status(expected_status=:not_started)
    # |> generate_peer_configs(base_config)
    # |> send_command(:configure_and_run)
    # |> get_status(expected_status=:just_started)
    # |> send_command(:get_ready)
    # |> get_status(expected_status=:ready)
    # |> send_command(:begin_pings)
    # Until then, here's a crude way to accomplish the same task: 

    # Setup configuration
    configs = generate_peer_configs(peers, common_config)

    status = get_status(peers, :not_started)
    Logger.info "Status: #{inspect status}"
    
    # Run following commands
    # configure_and_run |> get_ready |> begin_pings
    Enum.zip(peers, configs)
    |> Enum.map(fn {{peer_id, peer_name}, config} ->
      command = {:configure_and_run, config}
      {{peer_id, peer_name}, command}
    end)
    |> (fn peers_and_commands -> 
      Logger.info "sending command..., #{inspect peers_and_commands}"
      send_command(peers_and_commands)
      status = get_status(peers, :just_started)
      Logger.info "Status: #{inspect status}"
      peers
    end).()
    |> (fn peers ->
      peers
      |> Enum.map(fn {peer_id, peer_name} ->
        command = :get_ready
        {{peer_id, peer_name}, command}
      end)
      |> (fn peers_and_commands ->
        Logger.info "sending command..., #{inspect peers_and_commands}"
        send_command(peers_and_commands)

        status = get_status(peers, :ready)
        Logger.info "Status: #{inspect status}"
        peers
      end).()
    end).()
    |> (fn peers ->
      peers
      |> Enum.map(fn {peer_id, peer_name} ->
        command = :begin_pings
        {{peer_id, peer_name}, command}
      end)
      |> (fn peers_and_commands ->
        Logger.info "sending command..., #{inspect peers_and_commands}"
        send_command(peers_and_commands)
        status = get_status(peers, :pinging)
        Logger.info "Status: #{inspect status}"
        peers
      end).()
    end).()

  end

  def connect(peers) do
    peers
    |> Enum.map(fn {_peer_id, peer_name} ->
      status = Node.connect(peer_name)
      if status != true do
        Logger.error "controller - Not connected to #{peer_name}"
      end
      status
    end)
    |> Enum.filter(fn status -> status == true end)
    |> (fn connected ->
      case Enum.count(connected) == Enum.count(peers) do
        true ->
          {:ok, peers}
        false ->
          {:error, "Not connected to all peers"}
      end
    end).()
  end

  def verify_status(peers, expected_status) do
    peers
    |> get_status(expected_status)
    |> Enum.filter(fn status -> status == expected_status end)
    |> (fn status_ok_list ->
      case Enum.count(status_ok_list) == Enum.count(peers) do
        true ->
          {:ok, peers}
        false ->
          {:error, "All peers are not in expected state"}
      end
    end).()
  end

  def get_status(peers, expected_status) do
    peers
    |> Enum.map(fn {peer_id, _} ->
      name = ExperimentCoordinator.get_name(peer_id)
      case :global.whereis_name(name) do
        :undefined ->
          Logger.error "controller - #{name} not found through :global.whereis_name"
          :error
        pid ->
          {:ok, status} = GenServer.call(pid, :get_status)
          if status != expected_status do
            Logger.error "controller - #{name} is in #{status}. Expected #{expected_status}"
          end
          status
      end
    end)
  end

  def send_command(peers_and_commands) do
    peers_and_commands
    |> Enum.map(fn {{peer_id, _}, command} ->
      name = ExperimentCoordinator.get_name(peer_id)
      case :global.whereis_name(name) do
        :undefined ->
          Logger.error "controller - #{name} not found through :global.whereis_name"
          :error
        pid ->
          result = GenServer.call(pid, command)
          {peer_id, result}
      end
    end)
  end

  def generate_peer_configs(peers, base_config) do
    Enum.map(peers, fn {peer_id, peer_name} ->
      peer_config = [node_id: peer_id,
                     node_name: peer_name,
                     peers: other_nodes(peers, peer_id)
                    ]
      Keyword.merge(base_config, peer_config) |> Config.new()
    end)
  end

  defp other_nodes(peers, peer_id) do
    peers
    |> Enum.filter(fn {other_id, _peer_name} ->
      peer_id != other_id
    end)
    |> Enum.into([])
  end

  defp log_path(session_id) do
    "events_#{session_id}.log"
  end

end
