defmodule PoolgirlSupervisor do
  @moduledoc false
  
  use Supervisor
  require Logger

  def start_link(mod, arg) do
    Supervisor.start_link(__MODULE__, {mod, arg})
  end

  def init({mod, arg}) do
    children = [
      worker(mod, [arg], restart: :temporary)
    ]

    supervise(children, strategy: :simple_one_for_one)
  end
end