# Finance

[![CI](https://github.com/tubedude/finance-elixir/actions/workflows/ci.yml/badge.svg)](https://github.com/tubedude/finance-elixir/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/finance.svg)](https://hex.pm/packages/finance)
[![Hex Docs](https://img.shields.io/badge/hex-docs-8e5ea2.svg)](https://hexdocs.pm/finance)
[![Coverage Status](https://coveralls.io/repos/github/tubedude/finance-elixir/badge.svg?branch=main)](https://coveralls.io/github/tubedude/finance-elixir?branch=main)

An Elixir library for cash-flow analysis. It covers internal rate of return
(`xirr`/`irr`), net present value (`xnpv`/`npv`), and modified IRR (`mirr`),
along with the usual time-value-of-money and depreciation helpers. Options are
validated with `nimble_options`, and amounts may be `Decimal` values when you
have that optional dependency installed.

The functions are organised into domain modules:

- `Finance.CashFlow` — net present value and internal rate of return
  (`npv`, `xnpv`, `irr`, `xirr`, `mirr`), plus batched `irr_many`/`xirr_many`.
- `Finance.TVM` — time-value-of-money scalars (`pv`, `fv`, `pmt`, `ipmt`, `ppmt`,
  `nper`, `rate`) plus `amortization_schedule`.
- `Finance.Rates` — rate conversions (`effective_annual_rate`, `nominal_rate`,
  `continuous_to_periodic`).
- `Finance.Bonds` — fixed income (`price`, `ytm`, `duration`,
  `modified_duration`, `convexity`).
- `Finance.Depreciation` — `sln`, `syd`, `ddb`, `db`.
- `Finance.Returns` — performance and risk metrics (`volatility`, `cagr`,
  `payback_period`, `discounted_payback_period`, `profitability_index`, `twr`).
- `Finance.Solver` — the root-finding strategy behind the rate functions,
  swappable via the `:solver` option or `config :finance, solver: MySolver`.

The `Finance.CashFlow` rate and value functions come in two forms. The **dated**
ones (`xirr`, `xnpv`) work with flows that land on arbitrary dates, discounting
on an Actual/365 basis to match spreadsheet `XIRR`/`XNPV`. The **periodic** ones
(`irr`, `npv`, `mirr`) take a plain list of amounts spread over equally spaced
periods, for when the exact dates don't matter.

> The flat `Finance.foo` functions (e.g. `Finance.xirr/1`) still work but are
> **deprecated** — call the domain module instead. They will be removed in 2.0.

## Installation

Add `finance` to your dependencies in `mix.exs`:

```elixir
def deps do
  [{:finance, "~> 1.6"}]
end
```

If you also want to pass `Decimal` amounts, add `{:decimal, "~> 3.0"}` alongside
it.

## Usage

Pass a list of `{date, amount}` cash flows. Money coming in is positive and money
going out is negative, and the series needs at least one of each — without flows
in both directions there is no rate to solve for.

```elixir
Finance.CashFlow.xirr([
  {~D[2015-06-01],  1_000_000},
  {~D[2015-10-01], -2_200_000},
  {~D[2015-11-01],   -800_000}
])
#=> {:ok, 21.118359}
```

Dates can also be `{year, month, day}` tuples, and if it reads better you can
supply two parallel lists instead of pairs:

```elixir
Finance.CashFlow.xirr([{2019, 1, 1}, {2020, 1, 1}], [-1000, 1100])
#=> {:ok, 0.1}
```

If you would rather work with the rate directly than unwrap an `:ok` tuple,
`xirr!/1` and `xirr!/2` return it on its own and raise on error.

### Periodic functions

For flows at equally spaced periods `0, 1, 2, …`, pass a plain list of amounts:

```elixir
Finance.CashFlow.irr([-1000, 500, 500, 300])                                  #=> {:ok, 0.156579}
Finance.CashFlow.npv(0.1, [-1000, 600, 600])                                  #=> {:ok, 41.322314}
Finance.CashFlow.mirr([-120_000, 39_000, 30_000, 21_000, 37_000, 46_000], 0.10, 0.12)
#=> {:ok, 0.126094}
```

One thing to watch: `npv/2` places the first amount at period 0, which is what
makes `npv(irr(a), a) ≈ 0` hold. A spreadsheet `NPV` instead places the first
amount at period 1, so the two won't agree unless you account for that.

### Amounts: numbers, Decimal, and Money

Amounts may be any number — integer minor units such as cents, or floats. If your
app already depends on [`Decimal`](https://hex.pm/packages/decimal), you can pass
`Decimal` values straight through, with no conversion on your side:

```elixir
Finance.CashFlow.xirr([{~D[2019-01-01], Decimal.new("-1000")}, {~D[2020-01-01], Decimal.new("1100")}])
#=> {:ok, 0.1}
```

[`ex_money`](https://hex.pm/packages/ex_money) `%Money{}` values work too — common
when amounts come from an Ecto money column — and here the currency matters:

```elixir
Finance.CashFlow.xirr([{~D[2019-01-01], Money.new(:USD, "-1000")}, {~D[2020-01-01], Money.new(:USD, "1100")}])
#=> {:ok, 0.1}

# A series may not mix currencies:
Finance.CashFlow.irr([Money.new(:USD, "-1000"), Money.new(:EUR, "1100")])
#=> {:error, :mixed_currencies}
```

Both `Decimal` and `ex_money` are optional — apps that don't use them pull in
nothing extra (finance reads a `%Money{}`'s amount without depending on it). Plain
numbers and `Decimal` are currency-neutral, so they never trip the currency check.
Either way the result comes back as a float: rate-of-return math is inherently
irrational, so accepting these types is convenience at the call site, not added
precision in the answer.

### Errors

When the data can't produce a result, `xirr/1` and `xirr/2` return
`{:error, reason}`, where `reason` is one of:

| Reason                 | Meaning                                         |
| ---------------------- | ----------------------------------------------- |
| `:mismatched_lengths`  | date and amount lists differ in length          |
| `:insufficient_data`   | fewer than two distinct-date flows              |
| `:single_signed_flow`  | all amounts have the same sign                   |
| `:invalid_date`        | a date could not be parsed                       |
| `:did_not_converge`    | no rate found within the iteration limit         |
| `:mixed_currencies`    | a series mixes two or more `%Money{}` currencies |

## Day-count conventions

By default `xirr`/`xnpv` measure the time between dates as Actual/365 — the same
basis as spreadsheet `XIRR`. Instruments quoted under another convention (much
Brazilian debt is 30/360, not Actual/365) would otherwise silently disagree with
their term sheet, so the basis is selectable with `:basis`:

```elixir
Finance.CashFlow.xirr(flows, basis: :thirty_360)
```

Five conventions ship built in: `:actual_365` (default), `:actual_360`,
`:actual_actual` (ISDA), `:thirty_360` (US/NASD), and `:thirty_e_360` (Eurobond).
See `Finance.DayCount`.

`:basis` also takes any module implementing the `Finance.DayCount` behaviour, so a
calendar-based convention this dependency-free library can't carry — Brazilian
Business/252, say — lives in your app:

```elixir
defmodule MyApp.Business252 do
  @behaviour Finance.DayCount
  @impl true
  def year_fraction(date1, date2) do
    MyApp.Calendar.business_days_between(date1, date2) / 252
  end
end

Finance.CashFlow.xirr(flows, basis: MyApp.Business252)
```

## Solver

The rate functions (`irr`, `xirr`, `rate`, `ytm`) find their rate with a
safeguarded Newton-Raphson — the classic `rtsafe`. It brackets the root, then
each step is a Newton step when that step lands inside the bracket and is
converging fast enough, and a bisection step otherwise. This keeps Newton's
speed on ordinary flows and bisection's guaranteed convergence on awkward ones,
in a single pass. Because the maintained bracket always encloses a sign change,
the result is a genuine root rather than a stalled non-root. The solver is
swappable via the `:solver` option or `config :finance, solver: MySolver`.

`Finance.Solver.Brent` ships as an alternative: Brent's method, which is
derivative-free and so spends one NPV evaluation per step instead of two. On
short series the default is quicker, but Brent is faster on long-horizon flows —
long amortization schedules or bond ladders — where each evaluation is expensive.
Pass `solver: Finance.Solver.Brent` where it pays.

`bench/solver_strategies.exs` compares the two shipped solvers against reference
strategies across flow sets of growing length (NPV/derivative evaluations per
solve, and median time):

| flow set        | safeguarded Newton (default) | Brent              | plain Newton, then bisect | pure bisection    |
| --------------- | ---------------------------- | ------------------ | ------------------------- | ----------------- |
| 4 flows         | 13 evals · 7.5 µs            | 14 evals · 7.4 µs  | 8 evals · 3.7 µs          | 65 evals · 22 µs  |
| 60-period loan  | 13 evals · 94 µs             | 16 evals · 72 µs   | 44 evals · 256 µs         | 65 evals · 335 µs |
| 480-period loan | 31 evals · 1.5 ms            | 24 evals · 0.86 ms | 265 evals · 11.6 ms       | 65 evals · 2.3 ms |

Safeguarded Newton is the default all-rounder — fastest or near-fastest across
the board, and its bracket always encloses a sign change so the result is a
genuine root. `Finance.Solver.Brent` ties it on the shortest flows and pulls
ahead as they lengthen (~1.3× faster on the medium loan, ~1.7× on the long one),
because it spends one evaluation per step instead of two. Plain Newton edges both
out on the tiny set but burns its whole iteration budget on long flows before a
separate bisection pass rescues it (~8× slower than the default). Run it with
`mix run bench/solver_strategies.exs`.

### Batch and the native backend

`Finance.CashFlow.irr_many/2` and `xirr_many/2` solve a whole portfolio in one
call, returning a list of `{:ok, rate}` / `{:error, reason}` in order. They
dispatch through the solver's `solve_many/2`, which the default solver runs in
parallel across schedulers (chunked `Task.async_stream`).

Because the solver is swappable, a batch can run on a **native backend** with no
API change. [`finance_rustler`](https://github.com/tubedude/finance_rustler) is a
Rust (Rustler) backend whose `solve_many/2` runs the whole batch in one call over
a rayon thread pool — add it and point `:solver` at it:

```elixir
# mix.exs
{:finance, "~> 1.6"},
{:finance_rustler, "~> 0.2"}

# config/config.exs
config :finance, solver: FinanceRustler.Solver
```

Its `bench/solve_many.exs` compares the batch strategies — median time to solve a
whole batch:

| batch                  | native (rayon) | pure (chunked) | sequential |
| ---------------------- | -------------- | -------------- | ---------- |
| 1,000 × 4-flow         | 2.4 ms         | 7.6 ms         | 8.1 ms     |
| 1,000 × 60-period loan | 14.8 ms        | 23.7 ms        | 185 ms     |
| 5,000 × 60-period loan | 114 ms         | 98 ms          | 1,004 ms   |

Both parallel strategies beat a sequential map by 10–13×. The native backend is
fastest on batches of small series (~3× on the 4-flow set); the chunked pure
solver pulls even on large, heavier batches and uses far less memory. So the
native backend is an opt-in for throughput and for keeping heavy work off the
BEAM schedulers — not a requirement.

## Development

```bash
mix deps.get
mix test
mix format
mix credo --strict
mix dialyzer
```

See [CHANGELOG.md](CHANGELOG.md) for the release history.
