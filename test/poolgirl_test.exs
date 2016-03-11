defmodule PoolgirlTest do
  use ExUnit.Case
  doctest Poolgirl

  require Logger

  defmodule PoolgirlTestWorker do
    @moduledoc false

    use GenServer
    @behaviour PoolgirlWorker

    def start_link(_args) do
      GenServer.start_link(__MODULE__, [], [])
    end

    def init(_opts) do
      {:ok, :undefined}
    end

    def handle_call(:die, _from, state) do
      {:stop, {:error, :died}, :dead, state}
    end
    def handle_call(_msg, _from, state) do
      {:reply, :ok, state}
    end


    def handle_cast(_msg, state) do
      {:noreply, state}
    end
  end

  test "Check basic pool operation" do
    {:ok, pid} = new_pool(10, 5)
    assert 10 == length( pool_call(pid, :get_avail_workers))
    Poolgirl.checkout(pid)
    assert 9 ==  length(pool_call(pid, :get_avail_workers))
    worker = Poolgirl.checkout(pid)
    assert is_pid(worker) == :true
    assert 8 == length(pool_call(pid, :get_avail_workers))
    checkin_worker(pid, worker)
    assert 9 == length(pool_call(pid, :get_avail_workers))
    assert 1 == length(pool_call(pid, :get_all_monitors))
    :ok = pool_call(pid, :stop)
  end


  test "Check that the pool overflows properly" do
    {:ok, pid} = new_pool(5, 5)
    workers = Enum.to_list 0..6 |> Enum.map(fn _ -> Poolgirl.checkout(pid) end)
    assert 0 == length(pool_call(pid, :get_avail_workers))
    assert 7 == length(pool_call(pid, :get_all_workers))
    [a, b, c, d, e, f, g] = workers
    checkin_worker(pid, a)
    checkin_worker(pid, b)
    assert 0 == length(pool_call(pid, :get_avail_workers))
    assert 5 == length(pool_call(pid, :get_all_workers))
    checkin_worker(pid, c)
    checkin_worker(pid, d)
    assert 2 == length(pool_call(pid, :get_avail_workers))
    assert 5 == length(pool_call(pid, :get_all_workers))
    checkin_worker(pid, e)
    checkin_worker(pid, f)
    assert 4 == length(pool_call(pid, :get_avail_workers))
    assert 5 == length(pool_call(pid, :get_all_workers))
    checkin_worker(pid, g)
    assert 5 == length(pool_call(pid, :get_avail_workers))
    assert 5 == length(pool_call(pid, :get_all_workers))
    assert 0 == length(pool_call(pid, :get_all_monitors))
    :ok = pool_call(pid, :stop)
  end

test "Checks that the the pool handles the empty condition correctly when overflow is enabled" do
    {:ok, pid} = new_pool(5, 2)
    workers = Enum.to_list 0..6 |> Enum.map(fn _ -> Poolgirl.checkout(pid) end)
    assert 0 == length(pool_call(pid, :get_avail_workers))
    assert 7 == length(pool_call(pid, :get_all_workers))
    [a, b, c, d, e, f, g] = workers
    myself = self
    spawn(fn ->
        worker = Poolgirl.checkout(pid)
        send myself, :got_worker
        checkin_worker(pid, worker)
    end)
    # Spawned process should block waiting for worker to be available.
    receive do
        :got_worker -> assert :false
    after
        500 -> assert :true
    end
    checkin_worker(pid, a)
    checkin_worker(pid, b)

    # Spawned process should have been able to obtain a worker.
    receive do
        :got_worker -> assert :true
    after
        500 -> assert :false
    end
    assert 0 == length(pool_call(pid, :get_avail_workers))
    assert 5 == length(pool_call(pid, :get_all_workers))
    checkin_worker(pid, c)
    checkin_worker(pid, d)
    assert 2 == length(pool_call(pid, :get_avail_workers))
    assert 5 == length(pool_call(pid, :get_all_workers))
    checkin_worker(pid, e)
    checkin_worker(pid, f)
    assert 4 == length(pool_call(pid, :get_avail_workers))
    assert 5 == length(pool_call(pid, :get_all_workers))
    checkin_worker(pid, g)
    assert 5 == length(pool_call(pid, :get_avail_workers))
    assert 5 == length(pool_call(pid, :get_all_workers))
    assert 0 == length(pool_call(pid, :get_all_monitors))
    :ok = pool_call(pid, :stop)
  end


  test "Checks the pool handles the empty condition properly when overflow is disabled" do
    {:ok, pid} = new_pool(5, 0)
    workers = Enum.to_list 0..4 |> Enum.map(fn _ -> Poolgirl.checkout(pid) end)
    assert 0 == length(pool_call(pid, :get_avail_workers))
    assert 5 == length(pool_call(pid, :get_all_workers))
    [a, b, c, d, e] = workers
    myself = self
    spawn(fn ->
        worker = Poolgirl.checkout(pid)
        send myself, :got_worker
        checkin_worker(pid, worker)
    end)

    # Spawned process should block waiting for worker to be available.
    receive do
        :got_worker -> assert :false
    after
        500 -> assert :true
    end
    checkin_worker(pid, a)
    checkin_worker(pid, b)

    # Spawned process should have been able to obtain a worker.
    receive do
        :got_worker -> assert :true
    after
        500 -> assert :false
    end
    assert 2 == length(pool_call(pid, :get_avail_workers))
    assert 5 == length(pool_call(pid, :get_all_workers))
    checkin_worker(pid, c)
    checkin_worker(pid, d)
    assert 4 == length(pool_call(pid, :get_avail_workers))
    assert 5 == length(pool_call(pid, :get_all_workers))
    checkin_worker(pid, e)
    assert 5 == length(pool_call(pid, :get_avail_workers))
    assert 5 == length(pool_call(pid, :get_all_workers))
    assert 0 == length(pool_call(pid, :get_all_monitors))
    :ok = pool_call(pid, :stop)
  end

  test "Check that dead workers are only restarted when the pool is not full and the overflow count is 0. Meaning, don't restart overflow workers" do
    {:ok, pid} = new_pool(5, 2)
    worker = Poolgirl.checkout(pid)
    kill_worker(worker)
    assert 5 == length(pool_call(pid, :get_avail_workers))
    [a, b, c| _workers] = Enum.to_list 0..6 |> Enum.map(fn _ -> Poolgirl.checkout(pid) end)
    assert 0 == length(pool_call(pid, :get_avail_workers))
    assert 7 == length(pool_call(pid, :get_all_workers))
    kill_worker(a)
    assert 0 == length(pool_call(pid, :get_avail_workers))
    assert 6 == length(pool_call(pid, :get_all_workers))
    kill_worker(b)
    kill_worker(c)
    assert 1 == length(pool_call(pid, :get_avail_workers))
    assert 5 == length(pool_call(pid, :get_all_workers))
    assert 4 == length(pool_call(pid, :get_all_monitors))
    :ok = pool_call(pid, :stop)
  end


  test "Check that if a worker dies while the pool is full and there is a queued checkout, a new worker is started and the checkout serviced.
        If there are no queued checkouts, a new worker is not started." do
    {:ok, pid} = new_pool(5, 2)
    worker = Poolgirl.checkout(pid)
    kill_worker(worker)
    assert 5 == length(pool_call(pid, :get_avail_workers))
    [a, b | _workers] = Enum.to_list 0..6 |> Enum.map(fn _ -> Poolgirl.checkout(pid) end)
    assert 0 == length(pool_call(pid, :get_avail_workers))
    assert 7 == length(pool_call(pid, :get_all_workers))
    myself = self
    spawn(fn ->
        Poolgirl.checkout(pid)
        send myself, :got_worker
        # XXX: Don't release the worker. We want to also test what happens
        # when the worker pool is full and a worker dies with no queued
        # checkouts.
        :timer.sleep(5000)
    end)

    # Spawned process should block waiting for worker to be available.
    receive do
        :got_worker -> assert :false
    after
        500 -> assert :true
    end
    kill_worker(a)

    # Spawned process should have been able to obtain a worker.
    receive do
        :got_worker -> assert :true
    after
        1000 -> assert :false
    end
    kill_worker(b)
    assert 0 == length(pool_call(pid, :get_avail_workers))
    assert 6 == length(pool_call(pid, :get_all_workers))
    assert 6 == length(pool_call(pid, :get_all_monitors))
    :ok = pool_call(pid, :stop)
  end

  test "Check that if a worker dies while the pool is full and there's no overflow, a new worker is started unconditionally and any queued checkouts are serviced." do
    {:ok, pid} = new_pool(5, 0)
    worker = Poolgirl.checkout(pid)
    kill_worker(worker)
    assert 5 == length(pool_call(pid, :get_avail_workers))
    [a, b, c | _workers] = Enum.to_list 0..4 |> Enum.map(fn _ -> Poolgirl.checkout(pid) end)
    assert 0 == length(pool_call(pid, :get_avail_workers))
    assert 5 == length(pool_call(pid, :get_all_workers))
    myself = self()
    spawn(fn ->
        Poolgirl.checkout(pid)
        send myself, :got_worker
        # XXX: Do not release, need to also test when worker dies and no
        # checkouts queued.
        :timer.sleep(5000)
    end)
  
    # Spawned process should block waiting for worker to be available.
    receive do
        :got_worker -> assert :false
    after
        500 -> assert :true
    end
    kill_worker a
  
    # Spawned process should have been able to obtain a worker.
    receive do
        :got_worker -> assert :true
    after
        1000 -> assert :false
    end
    kill_worker b
    assert 1 == length(pool_call(pid, :get_avail_workers))
    assert 5 == length(pool_call(pid, :get_all_workers))
    kill_worker c
    assert 2 == length(pool_call(pid, :get_avail_workers))
    assert 5 == length(pool_call(pid, :get_all_workers))
    assert 3 == length(pool_call(pid, :get_all_monitors))
    :ok = pool_call(pid, :stop)
  end

 test "Check that when the pool is full, checkouts return 'full' when the option to use non-blocking checkouts is used." do
    {:ok, pid} = new_pool(5, 0)
    workers = Enum.to_list 0..4 |> Enum.map(fn _ -> Poolgirl.checkout(pid) end)
    assert 0 == length(pool_call(pid, :get_avail_workers))
    assert 5 == length(pool_call(pid, :get_all_workers))
    assert :full == Poolgirl.checkout(pid, :false)
    assert :full == Poolgirl.checkout(pid, :false)
    a = hd(workers)
    checkin_worker(pid, a)
    assert a == Poolgirl.checkout(pid)
    assert 5 == length(pool_call(pid, :get_all_monitors))
    :ok = pool_call(pid, :stop)
 end

  test "non-blocking checkouts is used" do
    {:ok, pid} = new_pool(5, 5)
    workers = Enum.to_list 0..9 |> Enum.map(fn _ -> Poolgirl.checkout(pid) end)
    assert 0 == length(pool_call(pid, :get_avail_workers))
    assert 10 == length(pool_call(pid, :get_all_workers))
    assert :full == Poolgirl.checkout(pid, :false)
    a = hd(workers)
    checkin_worker(pid, a)
    newworker = Poolgirl.checkout(pid, false)
    assert false == Process.alive?(a) # Overflow workers get shutdown
    assert is_pid(newworker)
    assert :full == Poolgirl.checkout(pid, :false)
    assert 10 == length(pool_call(pid, :get_all_monitors))
    :ok = pool_call(pid, :stop)
  end

  test "Check that a dead owner causes the pool to dismiss the worker and prune the state space." do
    {:ok, pid} = new_pool(5, 5)
    spawn(fn ->
        Poolgirl.checkout(pid)
        receive do after 500 -> exit(:normal) end
    end)
    :timer.sleep(1000)
    assert 5 == length(pool_call(pid, :get_avail_workers))
    assert 5 == length(pool_call(pid, :get_all_workers))
    assert 0 == length(pool_call(pid, :get_all_monitors))
    :ok = pool_call(pid, :stop)
  end

  test "checkin after exception in transaction" do
    {:ok, pool} = new_pool(2, 0)
    assert 2 == length(pool_call(pool, :get_avail_workers))
    tx = fn(worker) ->
        assert is_pid(worker)
        assert 1 == length(pool_call(pool, :get_avail_workers))
        throw  :it_on_the_ground
        assert :false
    end
    try do
        Poolgirl.transaction(pool, tx)
    catch
        :it_on_the_ground -> :ok
    end
    assert 2 == length(pool_call(pool, :get_avail_workers))
    :ok = pool_call(pool, :stop)
  end

  test "pool returns status" do
    {:ok, pool} = new_pool(2, 0)
    assert {:ready, 2, 0, 0} == Poolgirl.status(pool)
    Poolgirl.checkout(pool)
    assert {:ready, 1, 0, 1} == Poolgirl.status(pool)
    Poolgirl.checkout(pool)
    assert {:full, 0, 0, 2} == Poolgirl.status(pool)
    :ok = pool_call(pool, :stop)

    {:ok, pool2} = new_pool(1, 1)
    assert {:ready, 1, 0, 0} == Poolgirl.status(pool2)
    Poolgirl.checkout(pool2)
    assert {:overflow, 0, 0, 1} == Poolgirl.status(pool2)
    Poolgirl.checkout(pool2)
    assert {:full, 0, 1, 2} == Poolgirl.status(pool2)
   :ok = pool_call(pool2, :stop)

    {:ok, pool3} = new_pool(0, 2)
    assert {:overflow, 0, 0, 0} ==  Poolgirl.status(pool3)
    Poolgirl.checkout(pool3)
    assert {:overflow, 0, 1, 1} == Poolgirl.status(pool3)
    Poolgirl.checkout(pool3)
    assert {:full, 0, 2, 2} == Poolgirl.status(pool3)
   :ok = pool_call(pool3, :stop)

    {:ok, pool4} = new_pool(0, 0)
    assert {:full, 0, 0, 0} == Poolgirl.status(pool4)
   :ok = pool_call(pool4, :stop)
  end


  test "demonitors previously waiting processes" do
    {:ok, pool} = new_pool(1,0)
    myself = self()
    pid = spawn(fn ->
        w = Poolgirl.checkout(pool)
        send myself, :ok
        :timer.sleep(500)
        Poolgirl.checkin(pool, w)
        receive do :ok -> :ok end
    end)
    receive do :ok -> :ok end
    worker = Poolgirl.checkout(pool)
    assert 1 == length(get_monitors(pool))
    Poolgirl.checkin(pool, worker)
    :timer.sleep(500)
    assert 0 == length(get_monitors(pool))
    send pid, :ok
    :ok = pool_call(pool, :stop)
  end

  test "default strategy lifo" do
   # Default strategy is LIFO
    {:ok, pid} = new_pool(2, 0)
    worker1 = Poolgirl.checkout(pid)
    :ok = Poolgirl.checkin(pid, worker1)
    worker1 = Poolgirl.checkout(pid)
    Poolgirl.stop(pid)
  end

  test "lifo strategy" do
    {:ok, pid} = new_pool(2, 0, :lifo)
    worker1 = Poolgirl.checkout(pid)
    :ok = Poolgirl.checkin(pid, worker1)
    worker1 = Poolgirl.checkout(pid)
    Poolgirl.stop(pid)
  end

  test "fifo strategy" do
    {:ok, pid} = new_pool(2, 0, :fifo)
    worker1 = Poolgirl.checkout(pid)
    :ok = Poolgirl.checkin(pid, worker1)
    worker2 = Poolgirl.checkout(pid)
    assert worker1 != worker2
    worker1 = Poolgirl.checkout(pid)
    Poolgirl.stop(pid)
  end

  test "reuses waiting monitor on worker exit" do
    {:ok, pool} = new_pool(1,0)

    myself = self()
    pid = spawn(fn ->
        worker = Poolgirl.checkout(pool)
        send myself, {worker, worker}
        Poolgirl.checkout(pool)
        receive do
          :ok -> :ok
        end
    end)

    worker = receive do
              {worker, worker} -> worker
             end
    ref = Process.monitor(worker)
    Process.exit(worker, :kill)
    receive do
        {:"DOWN", ref, _, _, _} ->
            :ok
    end

    assert 1 == length(get_monitors(pool))

    send pid, :ok
    :ok = pool_call(pool, :stop)
  end

  test "test checkout with timeout" do
    {:ok, pid} = new_pool(5, 0)
    workers = Enum.to_list 0..4 |> Enum.map(fn _ -> Poolgirl.checkout(pid) end)
    assert 0 == length(pool_call(pid, :get_avail_workers))
    assert 5 == length(pool_call(pid, :get_all_workers))
    res = try do
      res = Poolgirl.checkout(pid)
    catch
      :exit, {:timeout, _} -> :ok
    end
    assert res == :ok
  end

  defp get_monitors(pid) do
    # Synchronise with the Pid to ensure it has handled all expected work.
    _ = :sys.get_status(pid)
    [{:monitors, monitors}] = Process.info(pid, [:monitors])
    monitors
  end

  defp pool_call(server_ref, request) do
      GenServer.call(server_ref, request)
  end

  defp new_pool(size, max_overflow) do
    Poolgirl.start_link([{:name, {:local, :poolgirl_test}}, {:worker_module, PoolgirlTestWorker}, {:size, size}, {:max_overflow, max_overflow}])
  end

  defp new_pool(size, max_overflow, strategy) do
    Poolgirl.start_link([{:name, {:local, :poolgirl_test}},
                        {:worker_module, PoolgirlTestWorker},
                        {:size, size}, {:max_overflow, max_overflow},
                        {:strategy, strategy}])
  end

  defp checkin_worker(pid, worker) do
    # There's no easy way to wait for a checkin to complete, because it's
    # async and the supervisor may kill the process if it was an overflow
    # worker. The only solution seems to be a nasty hardcoded sleep.
    Poolgirl.checkin(pid, worker)
    :timer.sleep(500)
  end

  defp kill_worker(pid) do
    Process.monitor(pid)
    pool_call(pid, :die)
    receive do
       {:"DOWN", _, :process, ^pid, _} -> :ok
    end
  end

end
