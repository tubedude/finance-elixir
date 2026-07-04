defmodule Finance.Solver do
  @moduledoc """
  The root-finding strategy behind the rate functions (`Finance.CashFlow.irr/2`,
  `Finance.CashFlow.xirr/2`, `Finance.TVM.rate/6`).

  A solver receives a normalized list of `{time, amount}` flows and finds the
  rate `r` that brings their net present value to zero. The default is
  `Finance.Solver.Newton`; swap in another implementation of this behaviour with
  the `:solver` option or `config :finance, solver: MySolver` — for example a
  future Nx / GPU-accelerated solver.
  """

  @typedoc "A normalized flow: `{time, amount}`, time in periods (or years)."
  @type flow :: {number, number}

  @doc """
  Solve `Σ amount_i / (1 + r)^t_i = 0` for `r`.

  `opts` carries `:guess`, `:tolerance`, `:max_iterations`, and `:precision`.
  Returns `{:ok, rate}` (rounded to `:precision`) or `{:error, :did_not_converge}`.
  """
  @callback solve(flows :: [flow], opts :: keyword) :: {:ok, float} | {:error, atom}
end
