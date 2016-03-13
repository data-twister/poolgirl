defmodule Poolgirl do
  @moduledoc false

  require PoolState
  require Logger

  @timeout 5000

  use GenServer

  ######################################################################################################################
  #
  #                                                  API INTERFACES
  #
  ######################################################################################################################
  #
  # FUNCTION: checkout
  #
  #############################################
  def checkout(pool), do: checkout(pool, :true)
  def checkout(pool, block), do: checkout(pool, block, @timeout)
  def checkout(pool, block, timeout) do
    cRef = make_ref
    try do
        GenServer.call(pool, {:checkout, cRef, block}, timeout)
    catch
        class, reason ->
            GenServer.cast(pool, {:cancel_waiting, cRef})
            :erlang.raise(class, reason, :erlang.get_stacktrace())
    end
  end
  #############################################
  #
  # FUNCTION: checkin
  #
  #############################################
  def checkin(pool, worker) when is_pid(worker), do: GenServer.cast(pool, {:checkin, worker})

  #############################################
  #
  # FUNCTION: status
  #
  #############################################
  def status(pool), do: GenServer.call(pool, :status)

  #############################################
  #
  # FUNCTION: stop
  #
  #############################################
  def stop(pool), do: GenServer.call(pool, :stop)

  #############################################
  #
  # FUNCTION: transaction
  #
  #############################################
  def transaction(pool, fun), do: transaction(pool, fun, @timeout)
  def transaction(pool, fun, timeout) do
    worker = checkout(pool, :true, timeout)
    try do
        fun.(worker)
    after
        :ok = checkin(pool, worker)
    end
  end

  #############################################
  #
  # FUNCTION: child_spec
  #
  #############################################
  def child_spec(pool_id, pool_args) do
    child_spec(pool_id, pool_args, [])
  end
  def child_spec(pool_id, pool_args, worker_args) do
    Supervisor.Spec.worker(Poolgirl, [pool_args, worker_args], [id: pool_id])
  end

  #############################################
  #
  # FUNCTION: start
  #
  #############################################
  def start(pool_args), do: start(pool_args, pool_args)
  def start(pool_args, worker_args), do: start_pool(:start, pool_args, worker_args)

  ######################################################################################################################
  #
  #                                                  GENSERVER API
  #
  ######################################################################################################################
  #
  # FUNCTION: start_link / caller side
  #
  #############################################
  def start_link(pool_args), do: start_link(pool_args, pool_args)
  def start_link(pool_args, worker_args), do:  start_pool(:start_link, pool_args, worker_args)


  #############################################
  #
  # FUNCTION: init
  #
  #############################################
  def init({pool_args, worker_args}) do
    Process.flag(:trap_exit, :true)
    waiting = :queue.new()
    monitors = :ets.new(:monitors, [:private])
    workers_to_reap = :ets.new(:workers_to_reap, [:private])
    init(pool_args, worker_args, %PoolState{waiting: waiting, monitors: monitors, workers_to_reap: workers_to_reap})
  end
  def init([{:worker_module, mod} | rest], worker_args, state) when is_atom(mod) do
    {:ok, sup} = PoolgirlSupervisor.start_link(mod, worker_args)
    init(rest, worker_args, %PoolState{ state | supervisor: sup})
  end
  def init([{:size, size} | rest], worker_args, state) when is_integer(size) do
    init(rest, worker_args, %PoolState{ state | size: size})
  end
  def init([{:max_overflow, max_overflow} | rest], worker_args, state) when is_integer(max_overflow) do
    init(rest, worker_args, %PoolState{ state | max_overflow: max_overflow})
  end
  def init([{:strategy, :lifo} | rest], worker_args, state), do: init(rest, worker_args, %PoolState{ state | strategy: :lifo})
  def init([{:strategy, :fifo} | rest], worker_args, state), do: init(rest, worker_args, %PoolState{ state | strategy: :fifo})
  def init([{:overflow_ttl, overflow_ttl} | rest], worker_args, state) when is_integer(overflow_ttl) do
    init(rest, worker_args, %PoolState{state | overflow_ttl: overflow_ttl})
  end
  def init([_M | rest], worker_args, state), do: init(rest, worker_args, state)
  def init([], _worker_args, %PoolState{size: size, supervisor: sup} = state) do
    workers = prepopulate(size, sup)
    {:ok, %PoolState{ state | workers: workers}}
  end

  ######################################################################################################################
  #
  #                                                  CAST MESSAGE FUNCTIONS
  #
  ######################################################################################################################
  #
  # MESSAGE: {:checkin, pid}
  #
  #############################################
  def handle_cast({:checkin, pid}, state = %PoolState{monitors: monitors}) do
    case :ets.lookup(monitors, pid) do
        [{pid, _, mRef}] ->
            :true = Process.demonitor(mRef)
            :true = :ets.delete(monitors, pid)
            newstate = handle_checkin(pid, state)
            {:noreply, newstate}
        [] ->
            {:noreply, state}
    end
  end

  #############################################
  #
  # MESSAGE: {:cancel_waiting, cRef}
  #
  #############################################
  def handle_cast({:cancel_waiting, cRef}, state) do
    case :ets.match(state.monitors, {:"$1", cRef, :"$2"}) do
        [[pid, mRef]] ->
            Process.demonitor(mRef, [:flush])
            :true = :ets.delete(state.monitors, pid)
            newstate = handle_checkin(pid, state)
            {:noreply, newstate}
        [] ->
            cancel = fn ({_, ref, mRef}) when ref == cRef ->
                             Process.demonitor(mRef, [:flush])
                             :false
                        (_) ->
                             :true
                     end
            waiting = :queue.filter(cancel, state.waiting)
            {:noreply, %PoolState{ state | waiting: waiting}}
    end
  end
  #############################################
  #
  # Unhandled cast msg
  #
  #############################################
  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  ######################################################################################################################
  #
  #                                                  CALL MESSAGE FUNCTIONS
  #
  ######################################################################################################################
  #
  # MESSAGE: {:checkout, cRef, block}
  #
  #############################################
  def handle_call({:checkout, cRef, block}, {from_pid, _} = from, state) do
    %PoolState{ supervisor:   sup,
                workers:      workers,
                monitors:     monitors,
                overflow:     overflow,
                overflow_ttl: overflow_ttl,
                max_overflow: max_overflow } = state
    case workers do
        [ pid | left ] when  overflow_ttl > 0 ->
            mRef = Process.monitor(from_pid)
            :true = :ets.insert(monitors, {pid, cRef, mRef})
            :ok = cancel_worker_reap(state, pid)
            {:reply, pid, %PoolState{ state | workers: left}}
        [ pid | left ] ->
            mRef = Process.monitor(from_pid)
            :true = :ets.insert(monitors, {pid, cRef, mRef})
            {:reply, pid, %PoolState{ state | workers: left}}
        [] when max_overflow > 0 and overflow < max_overflow ->
            {pid, mRef} = new_worker(sup, from_pid)
            :true = :ets.insert(monitors, {pid, cRef, mRef})
            {:reply, pid, %PoolState{ state | overflow: overflow + 1}}
        [] when block == :false ->
            {:reply, :full, state}
        [] ->
            mRef = Process.monitor(from_pid)
            waiting = :queue.in({from, cRef, mRef}, state.waiting)
            {:noreply, %PoolState{ state | waiting: waiting}}
    end
  end
  #############################################
  #
  # MESSAGE: :status
  #
  #############################################
  def handle_call(:status, _from, state) do
    %PoolState{ workers: workers, monitors: monitors, overflow: overflow } = state
    checked_out_workers = :ets.info(monitors, :size)
    statename = state_name(state)
    {:reply, {statename, length(workers), overflow, checked_out_workers}, state}
  end
  #############################################
  #
  # MESSAGE: :get_avail_workers
  #
  #############################################
  def handle_call(:get_avail_workers, _from, state), do: {:reply, state.workers, state}
  #############################################
  #
  # MESSAGE: :get_all_workers
  #
  #############################################
  def handle_call(:get_all_workers, _from, state) do
    worker_list = state.supervisor
                  |> Supervisor.which_children
    {:reply, worker_list, state}
  end
  #############################################
  #
  # MESSAGE: :get_all_monitors
  #
  #############################################
  def handle_call(:get_all_monitors, _from, state) do
    monitors = :ets.select(state.monitors, [{{:"$1", :"_", :"$2"}, [], [{{:"$1", :"$2"}}]}])
    {:reply, monitors, state}
  end
  #############################################
  #
  # MESSAGE: :stop
  #
  #############################################
  def handle_call(:stop, _from, state), do: {:stop, :normal, :ok, state}
  #############################################
  #
  # Unhandled call messages
  #
  #############################################
  def handle_call(_msg, _from, state) do
    reply = {:error, :invalid_message}
    {:reply, reply, state}
  end

  ######################################################################################################################
  #
  #                                                  GENERIC MESSAGE FUNCTIONS
  #
  ######################################################################################################################
  #
  # MESSAGE: :"DOWN"
  #
  #############################################
  def handle_info({:"DOWN", mRef, _, _, _}, state) do
    case :ets.match(state.monitors, {:"$1", :"_", mRef}) do
        [[pid]] ->
            :true = :ets.delete(state.monitors, pid)
            newstate = handle_checkin(pid, state)
            {:noreply, newstate}
        [] ->
            waiting = :queue.filter(fn {_, _, r} -> r != mRef end, state.waiting)
            {:noreply, %PoolState{ state | waiting: waiting}}
    end
  end
  #############################################
  #
  # MESSAGE: :"EXIT"
  #
  #############################################
  def handle_info({:"EXIT", pid, _reason}, state) do
    %PoolState{supervisor: sup, monitors: monitors, workers: workers} = state
    :ok = cancel_worker_reap(state, pid)
    case :ets.lookup(monitors, pid) do
        [{pid, _, mRef}] ->
            :true = Process.demonitor(mRef)
            :true = :ets.delete(monitors, pid)
            newstate = handle_worker_exit(pid, state)
            {:noreply, newstate}
        [] ->
            case Enum.member?(workers, pid) do
                :true ->
                    w = Enum.filter(workers, fn (x) -> x != pid end)
                    {:noreply, %PoolState{workers: [ new_worker(sup) | w ]}};
                :false ->
                    {:noreply, state}
            end
    end
  end
  #############################################
  #
  # MESSAGE: {:reap_worker, pid}
  #
  #############################################
  def handle_info({:reap_worker, pid}, state) do
    %PoolState{monitors: monitors, workers_to_reap: workers_to_reap} = state
    :true = :ets.delete(workers_to_reap, pid)
    case :ets.lookup(monitors, pid) do
      [{pid, _, mRef}] ->
        :true = :erlang.demonitor(mRef)
        :true = :ets.delete(monitors, pid)
        newstate = purge_worker(pid, state)
        {:noreply, newstate}
      [] ->
        newstate = purge_worker(pid, state)
        {:noreply, newstate}
    end
  end
  #############################################
  #
  # Unhandled generic message
  #
  #############################################
  def handle_info(_Info, state) do
    {:noreply, state}
  end

  def terminate(_reason, state) do
    :ok = :lists.foreach(fn (w) -> Process.unlink(w) end, state.workers)
    :true = Process.exit(state.supervisor, :shutdown)
    :ok
  end

  def code_change(_oldVsn, state, _extra), do: {:ok, state}

  ######################################################################################################################
  #
  #                                                  HELPER FUNCTIONS
  #
  ######################################################################################################################
  defp start_pool(start_fun, pool_args, worker_args) do
    case :proplists.get_value(:name, pool_args) do
        :undefined ->
            apply(GenServer, start_fun, [__MODULE__, {pool_args, worker_args}, []])
        name ->
            apply(GenServer, start_fun, [__MODULE__, {pool_args, worker_args}, [name: name]])
    end
  end

  defp new_worker(sup) do
    {:ok, pid} = Supervisor.start_child(sup, [])
    :true = Process.link(pid)
    pid
  end

  defp new_worker(sup, from_pid) do
    pid = new_worker(sup)
    ref = Process.monitor( from_pid)
    {pid, ref}
  end

  defp dismiss_worker(sup, pid) do
    :true = Process.unlink(pid)
    Supervisor.terminate_child(sup, pid)
  end

  defp cancel_worker_reap(state, pid) do
    case :ets.lookup(state.workers_to_reap, pid) do
        [{pid, tRef}] ->
          :erlang.cancel_timer(tRef)
          :true = :ets.delete(state.workers_to_reap, pid)
          :ok
        [] ->
          :ok
    end
  end

  defp purge_worker(pid, state) do
    %PoolState{supervisor: sup, workers: workers, overflow: overflow} = state
    case overflow > 0 do
      :true ->
        w = Enum.filter(workers, fn (p) -> p != pid end)
        :ok = dismiss_worker(sup, pid)
        %PoolState{ state | workers: w, overflow: overflow - 1}
      :false ->
        state
    end
  end

  defp prepopulate(n, _sup) when n < 1, do: []
  defp prepopulate(n, sup), do: prepopulate(n, sup, [])
  defp prepopulate(0, _sup, workers), do: workers
  defp prepopulate(n, sup, workers), do: prepopulate(n-1, sup, [ new_worker(sup) | workers])


  defp handle_pool_increase([], waiting, state), do: %PoolState{state | waiting: waiting }
  defp handle_pool_increase(workers, [], state), do: %PoolState{state | workers: [ workers | state.workers ]}
  defp handle_pool_increase([first_worker | workers], [first_wait | waiting], state) do

  end


  defp handle_checkin(pid, state) do
    %PoolState{ supervisor: sup, waiting: waiting, monitors: monitors, overflow: overflow,
                strategy: strategy, overflow_ttl: overflow_ttl, workers_to_reap: workers_to_reap } = state
    case :queue.out(waiting) do
        {{:value, {from, cRef, mRef}}, left} ->
          :true = :ets.insert(monitors, {pid, cRef, mRef})
          GenServer.reply(from, pid)
          %PoolState{ state | waiting: left}
        {:empty, empty} when overflow > 0 and overflow_ttl > 0 ->
          tRef = :erlang.send_after(overflow_ttl, self, {:reap_worker, pid})
          :true = :ets.insert(workers_to_reap, {pid, tRef})
          workers = case strategy do
                      :lifo -> [ pid | state.workers ]
                      :fifo -> [ state.workers | pid ]
                    end
          %PoolState{ state | workers: workers, waiting: empty}
        {:empty, empty} when overflow > 0 ->
          :ok = dismiss_worker(sup, pid)
          %PoolState{ state | waiting: empty, overflow: overflow - 1}
        {:empty, empty} ->
          workers = case strategy do
              :lifo -> [ pid | state.workers]
              :fifo -> state.workers ++ [ pid ]
          end
          %PoolState{state | workers: workers, waiting: empty, overflow: 0}
    end
  end

  defp handle_worker_exit(pid, state) do
    %PoolState{supervisor: sup, monitors: monitors, overflow: overflow} = state
    case :queue.out(state.waiting) do
        {{:value, {from, cRef, mRef}}, left_waiting} ->
            newworker = new_worker(state.supervisor)
            :true = :ets.insert(monitors, {newworker, cRef, mRef})
            GenServer.reply(from, newworker)
            %PoolState{ state | waiting: left_waiting}
        {:empty, empty} when overflow > 0 ->
           %PoolState{ state | overflow: overflow - 1, waiting: empty}
        {:empty, empty} ->
            workers = [ new_worker(sup) | Enum.filter(state.workers, fn (x) -> x != pid end)]
            %PoolState{ state | workers: workers, waiting: empty}
    end
  end

  defp state_name(state = %PoolState{overflow: overflow} ) when overflow < 1 do
    %PoolState{max_overflow: max_overflow, workers: workers} = state
    case length(workers) == 0 do
        :true when max_overflow < 1 -> :full
        :true -> :overflow
        :false -> :ready
    end
  end
  defp state_name(state = %PoolState{ overflow: overflow }) when overflow > 0 do
    %PoolState{ max_overflow: max_overflow, workers: workers, overflow: overflow } = state
    number_of_workers = length(workers)
    case max_overflow == overflow do
      :true when number_of_workers > 0 -> :ready
      :true -> :full
      :false -> :overflow
    end
  end
  defp state_name(_state), do: :overflow

end