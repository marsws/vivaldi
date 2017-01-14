defmodule Vivaldi.Peer.ExperimentCoordinator do
  @moduledoc """
  * Runs at each peer.
  * Passes commands from controller to peer processes
  * Answers status requests to controller

  The variable `status` used everywhere refers to the status of the experiment, and is
  part of the GenServer `state`
  """

  use GenServer

  require Logger

  alias Vivaldi.Peer.{AlgorithmSupervisor, Connections, Coordinate, CoordinateLogger, 
                      CoordinateStash, PingClient, PingServer}

  def start_link(node_id, state_agent) do
    name = get_name(node_id)
    GenServer.start_link(__MODULE__, [node_id, state_agent], name: name)
  end

  def get_name(node_id) do
    :"#{node_id}-experiment-coordinator"
  end

  def init(node_id, state_agent) do
    name = get_name(node_id)
    Logger.info "#{node_id} - starting #{name}..."
    status = Agent.get(state_agent, fn {status, _} -> status end)
    :yes = :global.register_name(name, self)
    {:ok, {status, state_agent, node_id}}
  end

  def handle_info({:EXIT, pid, reason}, {:pinging, state_agent, node_id}) do
    IO.puts "AlgorithmSupervisor,  #{pid} crashed #{inspect reason}. Restarting..."
    config = Agent.get(state_agent, fn {_, config} -> config end)
    spawn_algo_sup(config)
    {:noreply, {:pinging, state_agent, node_id}}
  end

  def handle_call({:configure, config}, _, {:not_started, state_agent, node_id}) do
    log_command_received(node_id, :configure, :not_started)
    Agent.update(state_agent, fn {status, _} -> {status, config} end)

    log_command_executed(node_id, :configure, :not_started)

    next_status = :just_started
    set_status(node_id, state_agent, :not_started, next_status)
    {:reply, :ok, {next_status, state_agent, node_id}}
  end

  def handle_call(:get_ready, _, {:just_started, state_agent, node_id}) do
    names = [
      Connections.get_name(node_id),
      Coordinate.get_name(node_id),
      CoordinateLogger.get_name(node_id),
      CoordinateStash.get_name(node_id),
      PingClient.get_name(node_id),
      PingServer.get_name(node_id),
    ]

    ready? = Enum.map(names, fn name -> 
      case Process.whereis(name) do
        nil ->
          Logger.warn "#{node_id} #{name} isn't running. We are not ready yet..."
          nil
        pid ->
          pid
      end
    end)
    |> Enum.filter(fn pid ->
      pid == nil
    end)
    |> (fn nil_statuses -> Enum.count(nil_statuses) == 0 end).()

    if ready? do
      {:reply, :ok, {:ready, state_agent, node_id}}
    else
      {:reply, :error, {:just_started, state_agent, node_id}}
    end
  end

  def handle_call(:begin_pings, _, {:ready, state_agent, node_id}) do
    name = PingClient.get_name(node_id)
    case log_command_and_get_process(node_id, :begin_pings, name, {:ready, state_agent, node_id}) do
      {:error, response} ->
        response
      {:ok, _} ->
        PingClient.begin_pings(node_id)
        log_command_executed(node_id, :begin_pings, :ready)

        next_status = :pinging
        set_status(node_id, state_agent, :ready, next_status)
        {:reply, :ok, {next_status, state_agent, node_id}}
    end

    name = PingClient.get_name(node_id)
    case Process.whereis(name) do
      nil ->
        message = "#{node_id}: cannot execute command :begin_pings. PingClient isn't running"
        Logger.error message
        {:reply, {:error, message}, {:just_started, state_agent, node_id}}
      _pid ->
        {:reply, :ok, {:pinging, state_agent, node_id}}
    end
  end

  # TODO: Handle invalid commands

  def spawn_algo_sup(config) do
    Process.flag :exit, true
    spawn_link(fn -> AlgorithmSupervisor.start_link(config) end)
  end

  def log_command_and_get_process(node_id, command, name, {status, state_agent, node_id}) do
    log_command_received(node_id, command, status)
    case Process.whereis(name) do
      nil ->
        message = "#{node_id} - ignored #{command}: #{name} isn't running"
        Logger.error message
        {:error, {:reply, {:error, message}, {status, state_agent, node_id}}}
      pid ->
        {:ok, pid}
    end
  end

  def set_status(node_id, state_agent, status, next_status) do
    if status != next_status do
      Agent.update(state_agent, fn {_, config} -> {next_status, config} end)
      Logger.info "#{node_id} - changed status #{status} -> #{next_status}"
    end
  end

  def log_command_received(node_id, command, status) do
    Logger.info "#{node_id} - at status: #{status} - received command #{command}"
  end

  def log_command_executed(node_id, command, status) do
    Logger.info "#{node_id} - at status: #{status} - executed command #{command}"
  end

end
