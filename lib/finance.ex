defmodule Finance do
  @moduledoc """
  Financial calculations for cash-flow analysis, time value of money,
  depreciation, and risk.

  The functions are organised into domain modules:

    * `Finance.CashFlow` — net present value and internal rate of return
      (`npv`, `xnpv`, `irr`, `xirr`, `mirr`).
    * `Finance.TVM` — time-value-of-money scalars (`pv`, `fv`, `pmt`, `nper`,
      `rate`).
    * `Finance.Depreciation` — `sln`, `syd`, `ddb`, `db`.
    * `Finance.Returns` — performance and risk metrics (`volatility`).
    * `Finance.Solver` — the root-finding strategy behind the rate functions,
      swappable via the `:solver` option or `config :finance, solver: MySolver`.

  ## Deprecated flat API

  Every function is also available directly on `Finance` (e.g. `Finance.xirr/1`),
  but those delegators are **deprecated** and will be removed in 2.0 — call the
  domain module instead, for example:

      Finance.CashFlow.xirr([{~D[2019-01-01], -1000}, {~D[2020-01-01], 1100}])
      #=> {:ok, 0.1}

  ## Options

  The rate-finding and value functions take an optional keyword list. Options are
  validated with `nimble_options`: an unknown key or bad value raises, while
  problems with the data come back as `{:error, reason}`.

  #{Finance.Shared.options_docs()}
  """

  @typedoc "A date, given either as a `Date` struct or as an Erlang-style `{year, month, day}` tuple."
  @type date :: Date.t() | {integer, integer, integer}

  @typedoc "A cash-flow amount: any number, or a `Decimal` when that optional dependency is installed."
  @type amount :: number | Decimal.t()

  @typedoc "A cash flow on a given date. Money coming in is positive, money going out is negative."
  @type cash_flow :: {date, amount}

  @typedoc "An annual rate of return expressed as a fraction, so `0.1` means 10%."
  @type rate :: float

  @typedoc "A keyword option accepted by the rate-finding and value functions."
  @type option ::
          {:guess, number}
          | {:tolerance, number}
          | {:max_iterations, pos_integer}
          | {:precision, non_neg_integer}
          | {:solver, module}

  @typedoc "A reason returned as `{:error, reason}` when the data can't yield a result."
  @type error ::
          :mismatched_lengths
          | :insufficient_data
          | :single_signed_flow
          | :invalid_date
          | :did_not_converge
          | :undefined

  # === Finance.CashFlow ====================================================

  @deprecated "Use Finance.CashFlow.xirr/1"
  defdelegate xirr(cash_flows), to: Finance.CashFlow

  @deprecated "Use Finance.CashFlow.xirr/2"
  defdelegate xirr(first, second), to: Finance.CashFlow

  @deprecated "Use Finance.CashFlow.xirr/3"
  defdelegate xirr(dates, values, opts), to: Finance.CashFlow

  @deprecated "Use Finance.CashFlow.xirr!/1"
  defdelegate xirr!(cash_flows), to: Finance.CashFlow

  @deprecated "Use Finance.CashFlow.xirr!/2"
  defdelegate xirr!(first, second), to: Finance.CashFlow

  @deprecated "Use Finance.CashFlow.xnpv/2"
  defdelegate xnpv(rate, cash_flows), to: Finance.CashFlow

  @deprecated "Use Finance.CashFlow.xnpv/3"
  defdelegate xnpv(rate, cash_flows, opts), to: Finance.CashFlow

  @deprecated "Use Finance.CashFlow.xnpv!/2"
  defdelegate xnpv!(rate, cash_flows), to: Finance.CashFlow

  @deprecated "Use Finance.CashFlow.irr/1"
  defdelegate irr(amounts), to: Finance.CashFlow

  @deprecated "Use Finance.CashFlow.irr/2"
  defdelegate irr(amounts, opts), to: Finance.CashFlow

  @deprecated "Use Finance.CashFlow.irr!/1"
  defdelegate irr!(amounts, opts \\ []), to: Finance.CashFlow

  @deprecated "Use Finance.CashFlow.npv/2"
  defdelegate npv(rate, amounts), to: Finance.CashFlow

  @deprecated "Use Finance.CashFlow.npv/3"
  defdelegate npv(rate, amounts, opts), to: Finance.CashFlow

  @deprecated "Use Finance.CashFlow.npv!/2"
  defdelegate npv!(rate, amounts), to: Finance.CashFlow

  @deprecated "Use Finance.CashFlow.mirr/3"
  defdelegate mirr(amounts, finance_rate, reinvest_rate, opts \\ []), to: Finance.CashFlow

  @deprecated "Use Finance.CashFlow.mirr!/3"
  defdelegate mirr!(amounts, finance_rate, reinvest_rate, opts \\ []), to: Finance.CashFlow

  # === Finance.TVM =========================================================

  @deprecated "Use Finance.TVM.fv/5"
  defdelegate fv(rate, nper, pmt, pv \\ 0.0, type \\ 0), to: Finance.TVM

  @deprecated "Use Finance.TVM.fv!/5"
  defdelegate fv!(rate, nper, pmt, pv \\ 0.0, type \\ 0), to: Finance.TVM

  @deprecated "Use Finance.TVM.pv/5"
  defdelegate pv(rate, nper, pmt, fv \\ 0.0, type \\ 0), to: Finance.TVM

  @deprecated "Use Finance.TVM.pv!/5"
  defdelegate pv!(rate, nper, pmt, fv \\ 0.0, type \\ 0), to: Finance.TVM

  @deprecated "Use Finance.TVM.pmt/5"
  defdelegate pmt(rate, nper, pv, fv \\ 0.0, type \\ 0), to: Finance.TVM

  @deprecated "Use Finance.TVM.pmt!/5"
  defdelegate pmt!(rate, nper, pv, fv \\ 0.0, type \\ 0), to: Finance.TVM

  @deprecated "Use Finance.TVM.nper/5"
  defdelegate nper(rate, pmt, pv, fv \\ 0.0, type \\ 0), to: Finance.TVM

  @deprecated "Use Finance.TVM.nper!/5"
  defdelegate nper!(rate, pmt, pv, fv \\ 0.0, type \\ 0), to: Finance.TVM

  @deprecated "Use Finance.TVM.rate/6"
  defdelegate rate(nper, pmt, pv, fv \\ 0.0, type \\ 0, opts \\ []), to: Finance.TVM

  @deprecated "Use Finance.TVM.rate!/6"
  defdelegate rate!(nper, pmt, pv, fv \\ 0.0, type \\ 0, opts \\ []), to: Finance.TVM

  # === Finance.Depreciation ================================================

  @deprecated "Use Finance.Depreciation.sln/3"
  defdelegate sln(cost, salvage, life), to: Finance.Depreciation

  @deprecated "Use Finance.Depreciation.sln!/3"
  defdelegate sln!(cost, salvage, life), to: Finance.Depreciation

  @deprecated "Use Finance.Depreciation.syd/4"
  defdelegate syd(cost, salvage, life, period), to: Finance.Depreciation

  @deprecated "Use Finance.Depreciation.syd!/4"
  defdelegate syd!(cost, salvage, life, period), to: Finance.Depreciation

  @deprecated "Use Finance.Depreciation.ddb/5"
  defdelegate ddb(cost, salvage, life, period, factor \\ 2), to: Finance.Depreciation

  @deprecated "Use Finance.Depreciation.ddb!/5"
  defdelegate ddb!(cost, salvage, life, period, factor \\ 2), to: Finance.Depreciation

  @deprecated "Use Finance.Depreciation.db/5"
  defdelegate db(cost, salvage, life, period, month \\ 12), to: Finance.Depreciation

  @deprecated "Use Finance.Depreciation.db!/5"
  defdelegate db!(cost, salvage, life, period, month \\ 12), to: Finance.Depreciation

  # === Finance.Returns =====================================================

  @deprecated "Use Finance.Returns.volatility/2"
  defdelegate volatility(prices, opts \\ []), to: Finance.Returns

  @deprecated "Use Finance.Returns.volatility!/2"
  defdelegate volatility!(prices, opts \\ []), to: Finance.Returns
end
