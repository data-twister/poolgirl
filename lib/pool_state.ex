defmodule PoolState do
  @moduledoc false

  defstruct supervisor:      nil,
            workers:         [],
            waiting:         nil,
            workers_to_reap: nil,
            monitors:        nil,
            size:            5,
            overflow:        0,
            max_overflow:    10,
            strategy:        :lifo,
            overflow_ttl:    0
end