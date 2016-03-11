defmodule PoolState do
  @moduledoc false

  defstruct supervisor:   nil,
            workers:      [],
            waiting:      nil,
            monitors:     nil,
            size:         5,
            overflow:     0,
            max_overflow: 10,
            strategy:     :lifo

end