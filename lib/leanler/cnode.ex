defmodule Leanler.CNode do
  @moduledoc """
  Owns one Lean C node: starts the executable, waits for it to join the cluster, and carries
  calls to it.

  The C node connects to this VM with `ei`, then announces itself with `{:leanler_ready, pid}`
  to this process's registered name. A call is `{from, ref, function, {arg, ...}}` sent to that pid;
  the answer is `{ref, {:ok, value} | {:error, reason}}`. The node exits when its stdin closes
  (the port closes, or this VM dies) or when the connection drops.

  The VM must be distributed: start it with `--sname`/`--name`, or call `Node.start/2`.
  """

  use GenServer
  require Logger

  @doc "Starts the C node at `executable`. `:name` is required, and is what the node reports to."
  @spec start_link(Path.t(), keyword()) :: GenServer.on_start()
  def start_link(executable, opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, {executable, name, Keyword.get(opts, :timeout, 15_000)}, name: name)
  end

  @doc """
  Calls `function` on the node. Returns `{:ok, value}` or `{:error, reason}`; a dead or missing
  server is `{:error, :noproc}` and a call that exceeds `timeout` is `{:error, :timeout}`.
  """
  @spec call(GenServer.server(), atom(), [term()], timeout()) :: {:ok, term()} | {:error, term()}
  def call(server, function, args, timeout \\ 30_000) do
    case resolve(server) do
      nil ->
        {:error, :noproc}

      pid ->
        mon = Process.monitor(pid)
        tag = make_ref()
        send(pid, {:leanler_call, self(), tag, function, args})

        receive do
          {^tag, result} ->
            Process.demonitor(mon, [:flush])
            result

          {:DOWN, ^mon, :process, _pid, _reason} ->
            {:error, :noproc}
        after
          timeout ->
            Process.demonitor(mon, [:flush])
            {:error, :timeout}
        end
    end
  end

  defp resolve(pid) when is_pid(pid), do: pid
  defp resolve(name) when is_atom(name), do: Process.whereis(name)
  defp resolve(_other), do: nil

  @impl true
  def init({executable, name, timeout}) do
    cond do
      not Node.alive?() ->
        {:stop, :not_distributed}

      not File.exists?(executable) ->
        {:stop, {:no_executable, executable}}

      true ->
        alive = "leanler_#{System.unique_integer([:positive])}"

        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [alive, Atom.to_string(node()), Atom.to_string(name)],
            env: [{~c"LEANLER_COOKIE", Atom.to_charlist(Node.get_cookie())}]
          ])

        receive do
          {:leanler_ready, remote} when is_pid(remote) ->
            {:ok, %{port: port, remote: remote, pending: %{}}}

          {^port, {:exit_status, status}} ->
            {:stop, {:cnode_exit, status}}
        after
          timeout ->
            Port.close(port)
            {:stop, :cnode_start_timeout}
        end
    end
  end

  @impl true
  def handle_info({:leanler_call, caller, tag, function, args}, state) do
    ref = make_ref()
    send(state.remote, {self(), ref, function, List.to_tuple(args)})
    {:noreply, put_in(state.pending[ref], {caller, tag})}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.pending, ref) do
      {{caller, tag}, pending} ->
        send(caller, {tag, result})
        {:noreply, %{state | pending: pending}}

      {nil, _pending} ->
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, {:cnode_exit, status}, state}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    Logger.warning("leanler cnode: #{String.trim(data)}")
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port, remote: remote}) do
    send(remote, {self(), make_ref(), :stop, {}})

    if Port.info(port) != nil do
      Port.close(port)
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok
end
