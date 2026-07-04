# Finance

[![CI](https://github.com/tubedude/finance-elixir/actions/workflows/ci.yml/badge.svg)](https://github.com/tubedude/finance-elixir/actions/workflows/ci.yml)

A small Elixir library for cash-flow analysis — internal rate of return
(`xirr`/`irr`), net present value (`xnpv`/`npv`), and modified IRR (`mirr`). Its
only required dependency is the tiny, zero-transitive-dependency `nimble_options`;
`Decimal` support is optional.

Functions come in two flavours: **dated** (`xirr`, `xnpv`) take flows at
arbitrary dates on an Actual/365 basis, matching spreadsheet `XIRR`/`XNPV`;
**periodic** (`irr`, `npv`, `mirr`) take a bare list of amounts at equally
spaced periods.

## Installation

Add `finance` to your dependencies in `mix.exs`:

```elixir
def deps do
  [{:finance, git: "https://github.com/tubedude/finance-elixir.git", tag: "1.0.0"}]
end
```

## Usage

Pass a list of `{date, amount}` cash flows. Positive amounts are inflows,
negative are outflows. The series must contain at least one of each.

```elixir
Finance.xirr([
  {~D[2015-06-01],  1_000_000},
  {~D[2015-10-01], -2_200_000},
  {~D[2015-11-01],   -800_000}
])
#=> {:ok, 21.118359}
```

Dates may also be `{year, month, day}` tuples, and you can supply two parallel
lists instead of pairs:

```elixir
Finance.xirr([{2019, 1, 1}, {2020, 1, 1}], [-1000, 1100])
#=> {:ok, 0.1}
```

`xirr!/1` and `xirr!/2` return the rate directly and raise on error.

### Periodic functions

For flows at equally spaced periods `0, 1, 2, …`, pass a bare amount list:

```elixir
Finance.irr([-1000, 500, 500, 300])                                  #=> {:ok, 0.156579}
Finance.npv(0.1, [-1000, 600, 600])                                  #=> {:ok, 41.322314}
Finance.mirr([-120_000, 39_000, 30_000, 21_000, 37_000, 46_000], 0.10, 0.12)
#=> {:ok, 0.126094}
```

Note `npv/2` places the first amount at period 0 (so `npv(irr(a), a) ≈ 0`),
which differs from spreadsheet `NPV` (first amount at period 1).

### Amounts and Decimal

Amounts may be any number — integer minor units (e.g. cents) or floats. If your
app already depends on [`Decimal`](https://hex.pm/packages/decimal), amounts may
be `Decimal` values directly, with no conversion on your side:

```elixir
Finance.xirr([{~D[2019-01-01], Decimal.new("-1000")}, {~D[2020-01-01], Decimal.new("1100")}])
#=> {:ok, 0.1}
```

`Decimal` is an **optional** dependency: apps that don't use it carry no extra
dependency. Results are always floats — XIRR's math is inherently irrational, so
Decimal input is an input convenience, not extra precision.

### Errors

`xirr/1` and `xirr/2` return `{:error, reason}` where `reason` is one of:

| Reason                 | Meaning                                         |
| ---------------------- | ----------------------------------------------- |
| `:mismatched_lengths`  | date and amount lists differ in length          |
| `:insufficient_data`   | fewer than two distinct-date flows              |
| `:single_signed_flow`  | all amounts have the same sign                   |
| `:invalid_date`        | a date could not be parsed                       |
| `:did_not_converge`    | no rate found within the iteration limit         |

## Development

```bash
mix deps.get
mix test
mix format
mix credo --strict
mix dialyzer
```

See [CHANGELOG.md](CHANGELOG.md) for the 1.0 rewrite notes.
