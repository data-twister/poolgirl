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

  #############################################
  #
  # FUNCTION: change_size
  #
  #############################################
  def change_size(pool, new_size) when is_integer(new_size), do: GenServer.call(pool, {:new_size, new_size})

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
    {:reply, {statename, {:available_workers, length(workers)},
                         {:overflow_workers, overflow},
                         {:checked_out_workers, checked_out_workers}}, state}
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
  # MESSAGE: {:new_size, new_size}
  #
  #############################################
  def handle_call({:new_size, new_size}, _from, %PoolState{size: new_size } = state) do
    {:reply, :ok, state}
  end
  def handle_call({:new_size, new_size}, _from, %PoolState{size: old_size} = state) when new_size > old_size do
    newstate = handle_size_increase(new_size - old_size, state)
    {:reply, :ok, %PoolState{newstate | size: new_size} }
  end
  def handle_call({:new_size, new_size}, _from, %PoolState{size: old_size } = state) when new_size < old_size and new_size >= 0 do
    newstate = handle_size_decrease(old_size - new_size, state)
    {:reply, :ok, %PoolState{newstate | size: new_size}}
  end
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

  defp handle_size_decrease(0, state), do: %PoolState{ state | to_be_removed: 0}
  defp handle_size_decrease(delta, state) do
    %PoolState{ supervisor:   sup,
                workers:      workers,
                overflow:     overflow,
                overflow_ttl: overflow_ttl,
                max_overflow: max_overflow } = state
    case workers do
      # We look for workers that have no ttl. We set a ttl for those
      [ _ | _ ] when  overflow_ttl > 0 and overflow < max_overflow ->
        response = increase_overflow_workers(workers, state)
        case response do
          {:ko, new_state} ->
            # All workers have a ttl set and we are below max_overflow. We should be good normally.
            new_state
          {:ok, new_state} ->
            # We found a worker that had no ttl. We set a ttl for it, increased overflow, decreased delta
            handle_size_decrease(delta - 1, new_state)
        end
      [pid | tail] when  overflow_ttl > 0 and overflow == max_overflow ->
        # We are at max_overflow. We should dismiss some workers immediately.
        # First, we should dismiss workers that have a ttl. Otherwise, we take the risk to dismiss too much workers
        response = dismiss_workers_with_ttl(workers, state)
        case response do
          {:ko, _ } ->
            # No workers have a ttl set. Normally, this use case should not happen (only when overflow = max_overflow = 0)
            :ok = cancel_worker_reap(state, pid) # normally, this call is useless
            :ok = dismiss_worker(sup, pid)
            handle_size_decrease(delta - 1, %PoolState{state | workers: tail })
          {:ok, new_state} ->
            # We found a worker that had a ttl. we dismissed it immediately and we decreased overflow
            handle_size_decrease(delta - 1, new_state)
        end
      [ pid | tail ] ->
        :ok = dismiss_worker(sup, pid)
        handle_size_decrease(delta - 1, %PoolState{ state | workers: tail})
      [] when overflow < max_overflow ->
        handle_size_decrease(delta - 1, %PoolState{state | overflow: overflow + 1})
      [] ->
        %PoolState{state | to_be_removed: delta}
    end
  end

  defp handle_size_increase(0, state), do: state
  defp handle_size_increase(delta, state) do
    %PoolState{supervisor: supervisor, workers:  workers,  waiting:  waiting,  workers_to_reap: workers_to_reap,
               monitors:   monitors,   overflow: overflow, strategy: strategy, overflow_ttl: overflow_ttl, to_be_removed: to_be_removed } = state
    if to_be_removed > 0 do
      handle_size_increase(delta - 1, %PoolState{state | to_be_removed: to_be_removed - 1})
    else
      # We should not destroy workers if it is not needed because it could be expensive to reallocate them
      # So we first check if they are already allocated workers.
      case :queue.out(waiting) do
        # We have pending tasks and we have some allocated workers that wait to be used
        {{:value, {from, cRef, mRef}}, left} when overflow > 0 and overflow_ttl > 0 ->
          [[pid, tRef] | _ ] = :ets.match(workers_to_reap,{:"$1",:"$2"})
          cancel_worker_reap(pid, state)
          :true = :ets.insert(monitors, {pid, cRef, mRef})
          GenServer.reply(from, pid)
          handle_size_increase(delta - 1, %PoolState{ state | waiting: left, overflow: overflow - 1})
        # We have exhausted allocated workers and we have still some pending tasks
        {{:value, {from, cRef, mRef}}, left} ->
          pid = new_worker(supervisor)
          :true = :ets.insert(monitors, {pid, cRef, mRef})
          GenServer.reply(from, pid)
          handle_size_increase(delta - 1, %PoolState{ state | waiting: left})
        # We have exhausted pending tasks
        {:empty, empty} when overflow > 0 and overflow_ttl > 0 ->
          case :ets.match(workers_to_reap,{:"$1",:"$2"}) do
            [[pid, tRef] | _ ] ->
              # We have allocated workers that wait to be used
              :erlang.cancel_timer(tRef)
              :true = :ets.delete(workers_to_reap, pid)
              new_workers = case strategy do
                :lifo -> [ pid | workers]
                :fifo -> workers ++ [ pid ]
              end
              handle_size_increase(delta - 1, %PoolState{ state | waiting: empty, overflow: overflow - 1, workers: new_workers})
            [] ->
              # Overflow workers are busy working. Decrease number of overflow workers
              handle_size_increase(delta - 1, %PoolState{ state | waiting: empty, overflow: overflow - 1})
          end
        # We are in overflow state. So we reduce this overflow number.
        {:empty, _} when overflow > 0 ->
          handle_size_increase(delta - 1, %PoolState{ state | overflow: overflow - 1})
        # We have nothing to do except allocating new workers.
        {:empty, _} ->
          extra_workers = prepopulate(delta, supervisor)
          handle_size_increase(0, %PoolState{ state | workers: workers ++ extra_workers })
      end
    end
  end

  defp dismiss_workers_with_ttl([], state), do: {:ko, state}
  defp dismiss_workers_with_ttl([pid | tail], %PoolState{supervisor: sup, overflow: overflow, workers_to_reap: workers_to_reap} = state) do
    if :ets.member(workers_to_reap, pid) do
      :ok = cancel_worker_reap(state, pid)
      :ok = dismiss_worker(sup, pid)
      {:ok, %PoolState{state | workers: tail, overflow: overflow - 1}}
    else
      dismiss_workers_with_ttl(tail, state)
    end
  end

  defp increase_overflow_workers([], state), do: {:ko, %PoolState{state | to_be_removed: 0}}
  defp increase_overflow_workers([pid | tail], %PoolState{overflow_ttl: overflow_ttl, overflow: overflow, workers_to_reap: workers_to_reap} = state )  do
    if :ets.member(workers_to_reap, pid) do
      increase_overflow_workers(tail, state)
    else
      tRef = :erlang.send_after(overflow_ttl, self, {:reap_worker, pid})
      :true = :ets.insert(workers_to_reap, {pid, tRef})
      {:ok, %PoolState{ state | workers: tail ++ pid, overflow: overflow + 1}}
    end
  end

  defp new_worker(sup) do
    {:ok, pid} = Supervisor.start_child(sup, [])
    :true = Process.link(pid)
    pid
  end

  defp new_worker(sup, from_pid) do
    pid = new_worker(sup)
    ref = Process.monitor(from_pid)
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

  defp handle_checkin(pid, state) do
    %PoolState{ supervisor: sup,    waiting: waiting, monitors: monitors, overflow: overflow, to_be_removed: to_be_removed,
                strategy: strategy, overflow_ttl: overflow_ttl, workers_to_reap: workers_to_reap } = state
    if to_be_removed > 0 do
          :ok = dismiss_worker(sup, pid)
          %PoolState{ state | to_be_removed: to_be_removed - 1}
    else
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
  end

  defp handle_worker_exit(pid, state) do
    %PoolState{supervisor: sup, monitors: monitors, overflow: overflow, to_be_removed: to_be_removed} = state
    if to_be_removed > 0 do
          %PoolState{ state | to_be_removed: to_be_removed - 1}
    else
      case :queue.out(state.waiting) do
        {{:value, {from, cRef, mRef}}, left_waiting} ->
          new_worker = new_worker(state.supervisor)
          :true = :ets.insert(monitors, {new_worker, cRef, mRef})
          GenServer.reply(from, new_worker)
          %PoolState{ state | waiting: left_waiting}
        {:empty, empty} when overflow > 0 ->
          %PoolState{ state | overflow: overflow - 1, waiting: empty}
        {:empty, empty} ->
          workers = [ new_worker(sup) | Enum.filter(state.workers, fn (x) -> x != pid end)]
          %PoolState{ state | workers: workers, waiting: empty}
      end
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