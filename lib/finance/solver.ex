defmodule Finance.Solver do
  @moduledoc """
  The root-finding strategy behind the rate functions (`Finance.CashFlow.irr/2`,
  `Finance.CashFlow.xirr/2`, `Finance.TVM.rate/6`).

  A solver implements two callbacks: `solve/2` finds the rate for one series, and
  `solve_many/2` solves a batch of independent series together. Both receive
  normalized `{time, amount}` flows. The default is `Finance.Solver.Newton`; swap
  in another implementation with the `:solver` option or
  `config :finance, solver: MySolver` — for example a native (Rustler) or Nx / GPU
  backend whose `solve_many/2` runs the whole batch in one call.
  """

  @typedoc "A normalized flow: `{time, amount}`, time in periods (or years)."
  @type flow :: {number, number}

  @doc """
  Solve `Σ amount_i / (1 + r)^t_i = 0` for `r`.

  `opts` carries `:guess`, `:tolerance`, `:max_iterations`, and `:precision`.
  Returns `{:ok, rate}` (rounded to `:precision`) or `{:error, :did_not_converge}`.
  """
  @callback solve(flows :: [flow], opts :: keyword) :: {:ok, float} | {:error, atom}

  @doc """
  Solve a batch of independent flow series in one call, returning a list of
  results in the same order as `batch`.

  This is the seam a native backend uses to solve many problems together (one
  NIF call, a GPU kernel, …). The default `Finance.Solver.Newton` parallelizes
  across schedulers with `Task.async_stream`.
  """
  @callback solve_many(batch :: [[flow]], opts :: keyword) :: [{:ok, float} | {:error, atom}]
end
