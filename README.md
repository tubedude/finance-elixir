# Finance

[![CI](https://github.com/tubedude/finance-elixir/actions/workflows/ci.yml/badge.svg)](https://github.com/tubedude/finance-elixir/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/finance.svg)](https://hex.pm/packages/finance)
[![Hex Docs](https://img.shields.io/badge/hex-docs-8e5ea2.svg)](https://hexdocs.pm/finance)

An Elixir library for cash-flow analysis. It covers internal rate of return
(`xirr`/`irr`), net present value (`xnpv`/`npv`), and modified IRR (`mirr`),
along with the usual time-value-of-money and depreciation helpers. Options are
validated with `nimble_options`, and amounts may be `Decimal` values when you
have that optional dependency installed.

The functions are organised into domain modules:

- `Finance.CashFlow` — net present value and internal rate of return
  (`npv`, `xnpv`, `irr`, `xirr`, `mirr`).
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
  [{:finance, "~> 1.0"}]
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

### Amounts and Decimal

Amounts may be any number — integer minor units such as cents, or floats. If your
app already depends on [`Decimal`](https://hex.pm/packages/decimal), you can pass
`Decimal` values straight through, with no conversion on your side:

```elixir
Finance.CashFlow.xirr([{~D[2019-01-01], Decimal.new("-1000")}, {~D[2020-01-01], Decimal.new("1100")}])
#=> {:ok, 0.1}
```

`Decimal` is an optional dependency, so apps that don't use it pull in nothing
extra. Either way the result comes back as a float: XIRR's math is inherently
irrational, so accepting `Decimal` is about convenience at the call site, not
added precision in the answer.

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

## Solver

The rate functions (`irr`, `xirr`, `rate`, `ytm`) find their rate with a
safeguarded Newton-Raphson — the classic `rtsafe`. It brackets the root, then
each step is a Newton step when that step lands inside the bracket and is
converging fast enough, and a bisection step otherwise. This keeps Newton's
speed on ordinary flows and bisection's guaranteed convergence on awkward ones,
in a single pass. Because the maintained bracket always encloses a sign change,
the result is a genuine root rather than a stalled non-root. The solver is
swappable via the `:solver` option or `config :finance, solver: MySolver`.

`bench/solver_strategies.exs` compares it against the alternatives across flow
sets of growing length (NPV/derivative evaluations per solve, and median time):

| flow set        | safeguarded Newton | plain Newton, then bisect | pure bisection    |
| --------------- | ------------------ | ------------------------- | ----------------- |
| 4 flows         | 13 evals · 6.0 µs  | 8 evals · 3.9 µs          | 65 evals · 22 µs  |
| 60-period loan  | 13 evals · 74 µs   | 44 evals · 277 µs         | 65 evals · 300 µs |
| 480-period loan | 31 evals · 1.5 ms  | 265 evals · 13.5 ms       | 65 evals · 3.1 ms |

Plain Newton edges ahead on short, well-behaved flows, but on long-horizon flows
it burns its whole iteration budget before a separate bisection pass rescues it
(~9× slower). Safeguarded Newton is the best all-rounder — fastest on the longer
sets, close behind on the shortest. Run it with `mix run bench/solver_strategies.exs`.

## Development

```bash
mix deps.get
mix test
mix format
mix credo --strict
mix dialyzer
```

See [CHANGELOG.md](CHANGELOG.md) for the 1.0 rewrite notes.
