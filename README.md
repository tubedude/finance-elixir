# Finance

[![CI](https://github.com/tubedude/finance-elixir/actions/workflows/ci.yml/badge.svg)](https://github.com/tubedude/finance-elixir/actions/workflows/ci.yml)

A small, dependency-free Elixir library for calculating **XIRR** — the internal
rate of return for cash flows that occur at irregular intervals.

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
