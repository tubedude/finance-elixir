# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`Finance` is a dependency-free Elixir library for cash-flow and time-value-of-money
math: XIRR/IRR, NPV/XNPV, MIRR, annuities (PV/FV/PMT/NPER/RATE), bonds, depreciation,
and return metrics. The rate functions track spreadsheet `XIRR`/`RATE` and Google
Sheets. Version 1.0 was a clean-break rewrite of the 0.x line; see `CHANGELOG.md`.

`decimal` is an **optional** dependency and ex_money `%Money{}` amounts are
supported — both without a hard dependency, guarded with `is_struct(value, Mod)`
(never `%Mod{}` patterns, which would force a compile-time dependency).

## Toolchain

`.tool-versions` (asdf) pins local dev to **Elixir 1.20 / OTP 29**, but `mix.exs`
requires only `~> 1.15`. CI (`.github/workflows/ci.yml`) tests 1.15/25, 1.18/27,
and 1.20/29, plus a job that runs the suite against Decimal 2.x. `mix format` and
`mix credo` run only on the newest version (the `lint` matrix flag), since the
formatter's output can differ across Elixir releases.

## Commands

```bash
mix deps.get
mix test                          # ExUnit + doctests + StreamData property tests
mix test test/finance_test.exs:42 # run a single test by file:line
mix format                        # uses .formatter.exs
mix credo --strict                # lint (must stay clean; CI enforces)
mix dialyzer                      # typespec check (first run builds the PLT, ~2 min)
MIX_ENV=test mix coveralls        # coverage — must stay at 100%
mix docs                          # ExDoc → doc/ (must build with 0 warnings)
mix run bench/solver_strategies.exs   # solver strategy benchmark
```

## Architecture

The public API lives in **domain modules**. The flat `Finance.*` functions (e.g.
`Finance.xirr/1`) are thin `@deprecated` delegates kept for the pre-1.2 names.

- `Finance.CashFlow` — `xirr`/`irr`/`xnpv`/`npv`/`mirr` (+ `!` variants) and the
  batch `irr_many`/`xirr_many`.
- `Finance.TVM` — `pv`/`fv`/`pmt`/`nper`/`rate`, `ipmt`/`ppmt`, `amortization_schedule`.
- `Finance.Bonds` — `price`/`ytm`/`duration`/`modified_duration`/`convexity`.
- `Finance.Depreciation` — `sln`/`syd`/`ddb`/`db`. `Finance.Rates` — rate-quote
  conversions. `Finance.Returns` — `volatility`, `cagr`, payback periods,
  `profitability_index`, `twr`.
- `Finance.Shared` (`@moduledoc false`) — cross-cutting helpers: amount coercion
  (`to_amount`, `check_currency`), the NimbleOptions schema, `round_value`,
  `present_value`, and the shared solver seam (`bracket/2`, `solve_batch/2`).

Cash-flow pipeline (`Finance.CashFlow`):

- **Two input shapes, one dispatcher.** `xirr/2` accepts *either* `{date, amount}`
  pairs + an options keyword list, *or* two parallel lists (dates, amounts).
  Disambiguated at runtime by `options?/1`: a keyword list has atom keys, while a
  pairs list (keys are dates) and an amounts list (numbers) never do. Dates may be
  `Date` structs or `{y, m, d}` tuples.
- **Normalization** (`normalize/1`): each flow's time becomes *years since the
  earliest date* (`Date.diff/2 / @days_in_year`, Actual/365); same-date flows are
  summed into a period→amount map — the solver input.
- **Validation**: needs ≥2 distinct-date flows and at least one positive *and* one
  negative amount, else `:insufficient_data` / `:single_signed_flow`.

Solver (`Finance.Solver` behaviour — `solve/2` + batch `solve_many/2`, swappable
via the `:solver` option or `config :finance, solver: Mod`):

- **`Finance.Solver.Newton`** (default) — safeguarded Newton-Raphson (the classic
  `rtsafe`): a Newton step when it stays inside the bracket and converges fast
  enough, a bisection step otherwise — one pass, not Newton-to-exhaustion-then-bisect.
- **`Finance.Solver.Brent`** — derivative-free Brent's method; one NPV evaluation
  per step instead of two, so it is faster on long-horizon flows.
- **Bracketing** (`Shared.bracket/2`) scans the rate domain on a geometric grid and
  returns the sign-change interval nearest `:guess`. This finds a root even when the
  NPV crosses zero an even number of times (multiple IRRs), and the guess selects
  which root — matching a guess-driven spreadsheet. `safe_low/1` floors the domain so
  discount factors stay finite over long horizons, and discounting uses a negative
  exponent (`amount * (1 + r)^-t`) so extreme rates underflow to 0 instead of
  overflowing (`:math.pow` raises on overflow). Any `ArithmeticError` maps to
  `:did_not_converge`.
- Full precision is kept internally; the result is rounded **once** at the end via
  `:precision`. On iteration exhaustion the solver returns its current bracketed
  estimate (a deliberate choice — the bracket keeps it bounded near the root).
- **Batch / native backend**: `solve_many/2` chunks work across schedulers
  (`Task.async_stream`); a native (`finance_rustler`) or Nx solver can override it.

Options (validated by NimbleOptions in `Finance.Shared`): `:guess` (0.1),
`:tolerance` (1.0e-9, on the rate step / bracket width — **not** the NPV),
`:max_iterations` (100), `:precision` (6), `:solver`.

## Testing conventions

- `test/finance_test.exs` keeps the original 0.x numeric cases as **regression
  anchors** (e.g. `21.118359`, `0.610359`), reproduced exactly. Changing the
  day-count basis, rounding, or solver will shift them — that's meaningful, not
  incidental.
- A **regression corpus** recreates cash flows from closed issues in
  numpy-financial (Python) and java-xirr (Java) that those libraries got wrong or
  crashed on; the XIRR/XNPV anchors match Excel/Google Sheets to ~8 decimals.
- Correctness is also checked structurally via StreamData properties (recover a
  known rate; assert NPV ≈ 0 at the returned rate). Prefer adding a property over
  hardcoding a hand-computed constant.
- Gates that must stay green: `mix credo --strict` (max function arity 8 — solver
  recursion state is bundled into tuples to satisfy this), `mix dialyzer`, **100%
  coverage** (every error branch needs a covering test), and `mix docs` with 0
  warnings.
