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
    newworker = Poolgirl.checkout(pid, :false)
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
    assert {:ready, {:available_workers, 2}, {:overflow_workers, 0}, {:checked_out_workers, 0}} == Poolgirl.status(pool)
    Poolgirl.checkout(pool)
    assert {:ready, {:available_workers, 1}, {:overflow_workers, 0}, {:checked_out_workers, 1}} == Poolgirl.status(pool)
    Poolgirl.checkout(pool)
    assert {:full, {:available_workers, 0}, {:overflow_workers, 0}, {:checked_out_workers, 2}} == Poolgirl.status(pool)
    :ok = pool_call(pool, :stop)

    {:ok, pool2} = new_pool(1, 1)
    assert {:ready, {:available_workers, 1}, {:overflow_workers, 0}, {:checked_out_workers, 0}} == Poolgirl.status(pool2)
    Poolgirl.checkout(pool2)
    assert {:overflow, {:available_workers, 0}, {:overflow_workers, 0}, {:checked_out_workers, 1}} == Poolgirl.status(pool2)
    Poolgirl.checkout(pool2)
    assert {:full, {:available_workers, 0}, {:overflow_workers, 1}, {:checked_out_workers, 2}} == Poolgirl.status(pool2)
   :ok = pool_call(pool2, :stop)

    {:ok, pool3} = new_pool(0, 2)
    assert {:overflow, {:available_workers, 0}, {:overflow_workers, 0}, {:checked_out_workers, 0}} ==  Poolgirl.status(pool3)
    Poolgirl.checkout(pool3)
    assert {:overflow, {:available_workers, 0}, {:overflow_workers, 1}, {:checked_out_workers, 1}} == Poolgirl.status(pool3)
    Poolgirl.checkout(pool3)
    assert {:full, {:available_workers, 0}, {:overflow_workers, 2}, {:checked_out_workers, 2}} == Poolgirl.status(pool3)
   :ok = pool_call(pool3, :stop)

    {:ok, pool4} = new_pool(0, 0)
    assert {:full, {:available_workers, 0}, {:overflow_workers, 0}, {:checked_out_workers, 0}} == Poolgirl.status(pool4)
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
    Poolgirl.checkout(pid)
    Poolgirl.stop(pid)
  end

  test "lifo strategy" do
    {:ok, pid} = new_pool(2, 0, :lifo)
    worker1 = Poolgirl.checkout(pid)
    :ok = Poolgirl.checkin(pid, worker1)
    Poolgirl.checkout(pid)
    Poolgirl.stop(pid)
  end

  test "fifo strategy" do
    {:ok, pid} = new_pool(2, 0, :fifo)
    worker1 = Poolgirl.checkout(pid)
    :ok = Poolgirl.checkin(pid, worker1)
    worker2 = Poolgirl.checkout(pid)
    assert worker1 != worker2
    Poolgirl.checkout(pid)
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
        {:"DOWN", ^ref, _, _, _} ->
            :ok
    end

    assert 1 == length(get_monitors(pool))

    send pid, :ok
    :ok = pool_call(pool, :stop)
  end

  test "test checkout with timeout" do
    {:ok, pid} = new_pool(5, 0)
    _workers = Enum.to_list 0..4 |> Enum.map(fn _ -> Poolgirl.checkout(pid) end)
    assert 0 == length(pool_call(pid, :get_avail_workers))
    assert 5 == length(pool_call(pid, :get_all_workers))
    res = try do
      Poolgirl.checkout(pid)
    catch
      :exit, {:timeout, _} -> :ok
    end
    assert res == :ok
  end

  test "pool overflow ttl workers" do
    {:ok, pid} = new_pool_with_overflow_ttl(1, 1, 1000)
    worker = Poolgirl.checkout(pid)
    worker1 = Poolgirl.checkout(pid)
    # Test pool behaves normally when full
    assert {:full, {:available_workers, 0}, {:overflow_workers, 1}, {:checked_out_workers, 2}} == Poolgirl.status(pid)
    assert :full == Poolgirl.checkout(pid, :false)
    # Test first worker is returned to list of available workers
    Poolgirl.checkin(pid, worker)
    :timer.sleep(500)
    assert {:ready, {:available_workers, 1}, {:overflow_workers, 1}, {:checked_out_workers, 1}} == Poolgirl.status(pid)
    # Ensure first worker is in fact being reused
    worker2 = Poolgirl.checkout(pid)
    assert {:full, {:available_workers, 0}, {:overflow_workers, 1}, {:checked_out_workers, 2}} == Poolgirl.status(pid)
    assert worker == worker2
    # Test second worker is returned to list of available workers
    Poolgirl.checkin(pid, worker1)
    :timer.sleep(500)
    assert {:ready, {:available_workers, 1}, {:overflow_workers, 1}, {:checked_out_workers, 1}} == Poolgirl.status(pid)
    # Ensure second worker is in fact being reused
    worker3 =  Poolgirl.checkout(pid)
    assert {:full, {:available_workers, 0}, {:overflow_workers, 1}, {:checked_out_workers, 2}} == Poolgirl.status(pid)
    assert worker1 == worker3
    # Test we've got two workers ready when two are checked in in quick
    # succession
    Poolgirl.checkin(pid, worker2)
    :timer.sleep(100)
    assert {:ready, {:available_workers, 1}, {:overflow_workers, 1}, {:checked_out_workers, 1}} == Poolgirl.status(pid)
    Poolgirl.checkin(pid, worker3)
    :timer.sleep(100)
    assert {:ready, {:available_workers, 2}, {:overflow_workers, 1}, {:checked_out_workers, 0}} == Poolgirl.status(pid)
    # Test an owner death
    spawn(fn() ->
               Poolgirl.checkout(pid)
               receive do after 100 -> exit(:normal) end
           end)
    assert {:ready, {:available_workers, 2}, {:overflow_workers, 1}, {:checked_out_workers, 0}} == Poolgirl.status(pid)
    assert 2 == length(pool_call(pid, :get_all_workers))
    # Test overflow worker is reaped in the correct time period
    :timer.sleep(850)
    # Test overflow worker is reaped in the correct time period
    assert {:ready, {:available_workers, 1}, {:overflow_workers, 0}, {:checked_out_workers, 0}} == Poolgirl.status(pid)
    # Test worker death behaviour
    worker4 = Poolgirl.checkout(pid)
    worker5 = Poolgirl.checkout(pid)
    Process.exit(worker5, :kill)
    :timer.sleep(100)
    assert {:overflow, {:available_workers, 0}, {:overflow_workers, 0}, {:checked_out_workers, 1}} == Poolgirl.status(pid)
    Process.exit(worker4, :kill)
    :timer.sleep(100)
    assert {:ready, {:available_workers, 1}, {:overflow_workers, 0}, {:checked_out_workers, 0}} == Poolgirl.status(pid)
    :ok = pool_call(pid, :stop)
  end

  test "basic pool increase" do
    {:ok, pool} = new_pool(1, 0)
    Poolgirl.change_size(pool, 2)
    assert {:ready, {:available_workers, 2}, {:overflow_workers, 0}, {:checked_out_workers, 0}} == Poolgirl.status(pool)
  end
  test "Increase when in full state" do
    {:ok, pool} = new_pool(2, 0)
    _workers = Enum.to_list 0..1 |> Enum.map(fn _ -> Poolgirl.checkout(pool) end)
    assert {:full, {:available_workers, 0}, {:overflow_workers, 0}, {:checked_out_workers, 2}} == Poolgirl.status(pool)
    Poolgirl.change_size(pool, 3)
    assert {:ready, {:available_workers, 1}, {:overflow_workers, 0}, {:checked_out_workers, 2}} == Poolgirl.status(pool)
  end
  test "Increase in overflow state" do
    {:ok, pool} = new_pool(2, 2)
    Enum.to_list 0..2 |> Enum.map(fn _ -> Poolgirl.checkout(pool) end)
    assert {:overflow, {:available_workers, 0}, {:overflow_workers, 1}, {:checked_out_workers, 3}} == Poolgirl.status(pool)
    Poolgirl.change_size(pool, 3)
    assert {:overflow, {:available_workers, 0}, {:overflow_workers, 0}, {:checked_out_workers, 3}} == Poolgirl.status(pool)
    Enum.to_list 0..1 |> Enum.map(fn _ -> Poolgirl.checkout(pool) end)
    assert {:full, {:available_workers, 0}, {:overflow_workers, 2}, {:checked_out_workers, 5}} == Poolgirl.status(pool)
  end
  test "Increase with ttl to dismiss worker" do
    {:ok, pool} = new_pool_with_overflow_ttl(3, 2, 1000)
    _workers = Enum.to_list 0..4 |> Enum.map(fn _ -> Poolgirl.checkout(pool) end)
    assert {:full, {:available_workers, 0}, {:overflow_workers, 2}, {:checked_out_workers, 5}} == Poolgirl.status(pool)
    Poolgirl.change_size(pool, 4)
    assert {:overflow, {:available_workers, 0}, {:overflow_workers, 1}, {:checked_out_workers, 5}} == Poolgirl.status(pool)
    pid = Poolgirl.checkout(pool)
    assert {:full, {:available_workers, 0}, {:overflow_workers, 2}, {:checked_out_workers, 6}} == Poolgirl.status(pool)
    checkin_worker(pool, pid)
    Poolgirl.change_size(pool, 5)
    :timer.sleep(1000)
    workers = pool_call(pool, :get_all_workers)
    assert :true = Enum.member?(workers, {:undefined, pid, :worker, [PoolgirlTest.PoolgirlTestWorker]})
  end

  test "pool decrease" do
    {:ok, pool} = new_pool(3, 0)
    Poolgirl.change_size(pool, 2)
    assert {:ready, {:available_workers, 2}, {:overflow_workers, 0}, {:checked_out_workers, 0}} == Poolgirl.status(pool)
  end

  test "pool decrease with overflow without ttl" do
    {:ok, pool} = new_pool(2, 1)
    [pid | workers] = Enum.to_list 1..3 |> Enum.map(fn _ -> Poolgirl.checkout(pool) end)
    # We have 3 workers busy - 2 normal, 1 overflow
    Poolgirl.change_size(pool, 1)
    # We have 3 workers busy - 3 checked out worker then - 1 normal, 1 overflow, 1 to be removed
    assert {:full, {:available_workers, 0}, {:overflow_workers, 1}, {:checked_out_workers, 3}} == Poolgirl.status(pool)
    checkin_worker(pool, pid)
    # We have 2 workers busy - 2 checked out worker then - 1 normal, 1 overflow
    assert {:full, {:available_workers, 0}, {:overflow_workers, 1}, {:checked_out_workers, 2}} == Poolgirl.status(pool)
    [ pid | _workers ] = workers
    checkin_worker(pool, pid)
    # We have 1 workers busy - 1 checked out worker then - 1 normal, 0 overflow
    assert {:overflow, {:available_workers, 0}, {:overflow_workers, 0}, {:checked_out_workers, 1}} == Poolgirl.status(pool)
    _pid = Poolgirl.checkout(pool)
    # We have 2 workers busy - 2 checked out worker then - 1 normal, 1 overflow
    assert {:full, {:available_workers, 0}, {:overflow_workers, 1}, {:checked_out_workers, 2}} == Poolgirl.status(pool)
  end

  test "pool decrease with available overflow workers" do
    {:ok, pool} = new_pool(5, 2)
    [pid1, pid2 | _workers] = Enum.to_list 1..5 |> Enum.map(fn _ -> Poolgirl.checkout(pool) end)
    # We have 5 workers busy - 5 checked out worker then - 5 normal, 0 overflow
    assert {:overflow, {:available_workers, 0}, {:overflow_workers, 0}, {:checked_out_workers, 5}} == Poolgirl.status(pool)
    Poolgirl.change_size(pool, 3)
    # We have 5 workers busy - 5 checked out worker then - 3 normal, 2 overflow
    assert {:full, {:available_workers, 0}, {:overflow_workers, 2}, {:checked_out_workers, 5}} == Poolgirl.status(pool)
    checkin_worker(pool, pid1)
    # We have 4 workers busy - 4 checked out worker then - 3 normal, 1 overflow
    assert {:overflow, {:available_workers, 0}, {:overflow_workers, 1}, {:checked_out_workers, 4}} == Poolgirl.status(pool)
    pid3 = Poolgirl.checkout(pool)
    # We have 4 workers busy - 5 checked out worker then - 3 normal, 2 overflow
    assert {:full, {:available_workers, 0}, {:overflow_workers, 2}, {:checked_out_workers, 5}} == Poolgirl.status(pool)
    Poolgirl.change_size(pool, 1)
    # We have 4 workers busy - 5 checked out worker then: 1 normal, 2 overflow, 2 to be removed
    checkin_worker(pool, pid2)
    checkin_worker(pool, pid3)
    # We have 3 workers busy - 3 checked out worker then: 1 normal, 2 overflow
    assert {:full, {:available_workers, 0}, {:overflow_workers, 2}, {:checked_out_workers, 3}} == Poolgirl.status(pool)
    Poolgirl.change_size(pool, 4)
    # We have 3 workers busy - 3 checked out worker then: 3 normal, 1 available
    assert {:ready, {:available_workers, 1}, {:overflow_workers, 0}, {:checked_out_workers, 3}} == Poolgirl.status(pool)
    Poolgirl.change_size(pool, 3)
    # We have 3 workers busy - 3 checked out worker then: 3 normal, 0 available
    assert {:overflow, {:available_workers, 0}, {:overflow_workers, 0}, {:checked_out_workers, 3}} == Poolgirl.status(pool)
    Poolgirl.change_size(pool, 2)
    # We have 3 workers busy - 3 checked out worker then: 2 normal, 1 overflow
    assert {:overflow, {:available_workers, 0}, {:overflow_workers, 1}, {:checked_out_workers, 3}} == Poolgirl.status(pool)
    Poolgirl.change_size(pool, 1)
    # We have 3 workers busy - 3 checked out worker then: 1 normal, 2 overflow, 0 to be removed
    assert {:full, {:available_workers, 0}, {:overflow_workers, 2}, {:checked_out_workers, 3}} == Poolgirl.status(pool)
    Poolgirl.change_size(pool, 0)
    # We have 3 workers busy - 3 checked out worker then: 0 normal, 2 overflow, 1 to be removed
    assert {:full, {:available_workers, 0}, {:overflow_workers, 2}, {:checked_out_workers, 3}} == Poolgirl.status(pool)
    [{:undefined, pid1, :worker, [PoolgirlTest.PoolgirlTestWorker]}, _pid2, _pid3] = pool_call(pool, :get_all_workers)
    kill_worker(pid1)
    # We have 2 workers busy - 2 checked out worker then: 0 normal, 2 overflow
    assert {:full, {:available_workers, 0}, {:overflow_workers, 2}, {:checked_out_workers, 2}} == Poolgirl.status(pool)
    [{:undefined, pid2, :worker, [PoolgirlTest.PoolgirlTestWorker]}, {:undefined, pid3, :worker, [PoolgirlTest.PoolgirlTestWorker]}] = pool_call(pool, :get_all_workers)
    kill_worker(pid2)
    # We have 1 workers busy - 1 checked out worker then: 0 normal, 1 overflow
    assert {:overflow, {:available_workers, 0}, {:overflow_workers, 1}, {:checked_out_workers, 1}} == Poolgirl.status(pool)
    kill_worker(pid3)
    # We have 1 workers busy - 0 checked out worker then: 0 normal, 0 overflow
    assert {:overflow, {:available_workers, 0}, {:overflow_workers, 0}, {:checked_out_workers, 0}} == Poolgirl.status(pool)
  end

  test "pool decrease with overflow with ttl" do
    {:ok, pool} = new_pool_with_overflow_ttl(5, 2, 1000)
    [ pid1, pid2 | _workers] = Enum.to_list 1..5 |> Enum.map(fn _ -> Poolgirl.checkout(pool) end)
    Poolgirl.change_size(pool, 3)
    # Here two workers are in excess -> They are put with overflow workers and they expire after 1000 ms
    checkin_worker(pool, pid1)
    checkin_worker(pool, pid2)
    :timer.sleep(1000)
    assert {:overflow, {:available_workers, 0}, {:overflow_workers, 0}, {:checked_out_workers, 3}} == Poolgirl.status(pool)
  end

  test "pool decrease with overflow with ttl. Reuse of one of them" do
    {:ok, pool} = new_pool_with_overflow_ttl(5, 2, 1000)
    [pid1, pid2 | _workers] = Enum.to_list 1..5 |> Enum.map(fn _ -> Poolgirl.checkout(pool) end)
    Poolgirl.change_size(pool, 3)
    # Here two workers are in excess -> They are put with overflow workers
    # We reuse on of them immediately and the other one expire after 1000 ms
    checkin_worker(pool, pid1)
    checkin_worker(pool, pid2)
    _pid3 = Poolgirl.checkout(pool)
    :timer.sleep(1000)
    assert {:overflow, {:available_workers, 0}, {:overflow_workers, 1}, {:checked_out_workers, 4}} == Poolgirl.status(pool)
  end
  test "pool decrease with overflow with ttl. All are used" do
    {:ok, pool} = new_pool_with_overflow_ttl(5, 2, 1000)
    [pid1, pid2 | _workers] = Enum.to_list 1..7 |> Enum.map(fn _ -> Poolgirl.checkout(pool) end)
    Poolgirl.change_size(pool, 3)
    # Here two workers are in excess -> They are immediately dismissed when checked in.
    checkin_worker(pool, pid1)
    checkin_worker(pool, pid2)
    pid3 = Poolgirl.checkout(pool, :false)
    assert pid3 == :full
    assert {:full, {:available_workers, 0}, {:overflow_workers, 2}, {:checked_out_workers, 5}} == Poolgirl.status(pool)
  end

  test "Take all workers, decrease size and then increase" do
    {:ok, pool} = new_pool_with_overflow_ttl(5, 2, 1000)
    [pid1, pid2 | _workers] = Enum.to_list 1..5 |> Enum.map(fn _ -> Poolgirl.checkout(pool) end)
    Poolgirl.change_size(pool, 3)
    # Here two workers are in excess -> They are in overflow workers.
    Poolgirl.checkin(pid1, pool)
    Poolgirl.checkin(pid2, pool)
    # We come back in the initial state. Overflow workers come back in normal workers and are not dismissed
    Poolgirl.change_size(pool, 5)
    :timer.sleep(1000)
    assert {:overflow, {:available_workers, 0}, {:overflow_workers, 0}, {:checked_out_workers, 5}} == Poolgirl.status(pool)
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
    Poolgirl.start_link([{:name, {:local, :poolgirl_test}}, {:worker_module, PoolgirlTestWorker}, {:size, size}, {:max_overflow, max_overflow},
                        {:strategy, strategy}])
  end

  defp new_pool_with_overflow_ttl(size, max_overflow, overflow_ttl) do
    Poolgirl.start_link([{:name, {:local, :poolgirl_test_ttl}}, {:worker_module, PoolgirlTestWorker}, {:size, size}, {:max_overflow, max_overflow},
                         {:overflow_ttl, overflow_ttl}])
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
