defmodule PoolgirlWorker do
  @moduledoc false
  use Behaviour

  @type worker_args :: Keyword

  defcallback start_link(worker_args) :: pid | term
end