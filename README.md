# Poolgirl

This library is a translation in Elixir of the famous poolboy : https://github.com/devinus/poolboy ... 
I just don't like to mix Erlang and Elixir code (Elixir is clearer than its father) and this library is a great one.

# Things adding compared with poolboy

Version 0.1.0
* ttl to deallocate overflow workers ( see PR of poolboy )
* changing pool size dynamically

Version 0.2.0
* Possibility to broadcast messages to all workers.

# API
We first define quickly a worker. Notice handle_info callback
<pre><code>iex(2)>  defmodule PoolgirlTestWorker do
...(2)>    @moduledoc false
...(2)>
...(2)>    use GenServer
...(2)>    @behaviour PoolgirlWorker
...(2)>
...(2)>    def start_link(_args) do
...(2)>      GenServer.start_link(__MODULE__, [], [])
...(2)>    end
...(2)>
...(2)>    def init(_opts) do
...(2)>      {:ok, :undefined}
...(2)>    end
...(2)>
...(2)>    def handle_call(_msg, _from, state) do
...(2)>      {:reply, :ok, state}
...(2)>    end
...(2)>    def handle_cast(_msg, state) do
...(2)>      {:noreply, state}
...(2)>    end
...(2)>    def handle_info({:broadcast, msg}, state) do
...(2)>      {:noreply, state}
...(2)>    end
...(2)>  end
</pre></code>
We start the pool with a dynamic configuration but we could have put it 
in our <env>.exs config file.
<pre><code>iex(3)>  Poolgirl.start_link([{:name, {:local, :poolgirl_test}}, 
{:worker_module, YourModule}, {:size, 10}, {:max_overflow, 5}, 
{:broadcast_to_workers, :true}])
{:ok, #PID<0.498.0>}
</pre></code>
We can check out a worker to do some work
<pre><code>iex(4)> pid = Poolgirl.checkout(:poolgirl_test)
\#PID<0.509.0>
</pre></code>

We have to check in it when we have finished to use it
<pre><code>iex(5)> Poolgirl.checkin(:poolgirl_test, pid)
:ok
</pre></code>
We can send a message to the entire pool, even to workers that are 
working when the message is broadcast. You just have to implement the
callback in your worker. The message is like {:broadcast, msg}. msg is 
your message and :broadcast atom is added. So when the following call is
done, the message that reaches the worker is {:broadcast, {:test}}
<pre><code>iex(6)> Poolgirl.async_broadcast_to_pool(:poolgirl_test, {:test})
:ok
</pre></code>
You can have a report of the pool
<pre><code>iex(7)> Poolgirl.status(:poolgirl_test)
{:ready, {:available_workers, 10}, {:overflow_workers, 0}, {:checked_out_workers, 0}}
</pre></code>
You can reduce / increase the pool size. When you increase the pool, if 
some process are waiting for a worker, they obtain a worker immediately. 
If some workers are in an overflow state, they become "regular" workers 
(up to the correct size of course). 
If you decrease the pool size, the pool is not reduce if all workers are
busy working. The number of workers will be reduced when the workers are
checked in. You can set an overflow_ttl. This means that the worker is 
not destroyed until the ttl has expired. This option permits to save time.
<pre><code>iex(8)> Poolgirl.change_size(:poolgirl_test, 5)
:ok
</pre></code>
This function gives the configuration. All these parameters can be set in
the configuration.
<pre><code>iex(9)> Poolgirl.give_conf(:poolgirl_test)     
%{broadcast_to_workers: true, max_overflow: 5, overflow_ttl: 0, size: 5,
  strategy: :lifo}
</code></pre>
In your config file, you can put something like :
<pre><code>config :poolgirl, [ worker_module: YourModule, size: 10, max_overflow: 5 ] </code></pre>
and then in your supervisor code
<pre><code>config = Application.get_env(:my_app, :poolgirl)
children = [
  Poolgirl.child_spec(:pool_id, config, [ < args and options> ])
]
</pre></code>



# Bugs
Bugs are mine and for the rest, all credits are for Devinus and his fellow maintainers of the project. Support them ! 

# License

Poolgirl, like her boyfriend, is available in the public domain (see UNLICENSE). Poolgirl is also optionally available under the ISC license (see LICENSE), meant especially for jurisdictions that do not recognize public domain works.