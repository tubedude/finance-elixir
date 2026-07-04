# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-module, dependency-free Elixir library (`Finance`) that calculates
**XIRR** — the internal rate of return for cash flows at irregular intervals.
The entire implementation is `lib/finance.ex`. Version 1.0 was a clean-break
rewrite; see `CHANGELOG.md` for what changed from the 0.x line.

## Toolchain

Elixir/OTP are pinned in `.tool-versions` (asdf): **Elixir 1.20 / OTP 29**.
`mix.exs` requires `~> 1.18`. CI (`.github/workflows/ci.yml`) tests on both
1.18/27 and 1.20/29.

## Commands

```bash
mix deps.get
mix test                       # ExUnit + doctests + StreamData property tests
mix test test/finance_test.exs:26   # run a single test by file:line
mix format                     # uses .formatter.exs
mix credo --strict             # lint (must stay clean; CI enforces)
mix dialyzer                   # typespec check (first run builds the PLT, ~2 min)
mix docs                       # ExDoc → doc/
```

## Architecture

The public surface is `Finance.xirr/1,2,3` (plus `xirr!` bang variants),
returning `{:ok, rate}` or `{:error, atom}`. Key facts, all in `lib/finance.ex`:

- **Two input shapes, one dispatcher.** `xirr/2` accepts *either* `{date, amount}`
  pairs + an options keyword list, *or* two parallel lists (dates, amounts).
  They're disambiguated at runtime by `options?/1`: a keyword list has atom
  keys, while a pairs list (keys are dates) and an amounts list (numbers) never
  do — so the shapes can't be confused. Dates may be `Date` structs or
  `{y, m, d}` tuples.
- **Normalization** (`normalize/1`): dates are parsed, each flow's time becomes
  *years since the earliest date* (`Date.diff/2 / 365.0`, Actual/365), and flows
  on the same date are summed into a period→amount map. This is the solver input.
- **Validation** (`validate/1`): needs ≥2 distinct-date flows and at least one
  positive *and* one negative amount, else `:insufficient_data` /
  `:single_signed_flow`.
- **Solver** (`solve/2`): Newton-Raphson (`newton/4` + analytic derivative
  `dnpv/2`) with a **bracketing bisection fallback** (`bisect/4`) when Newton
  leaves the `(-1, ∞)` domain or stalls. Both are bounded by `:max_iterations`;
  failure returns `:did_not_converge`. Any `ArithmeticError` is also mapped to
  `:did_not_converge`. Full precision is kept internally; the result is rounded
  **once** at the end via `:precision`.
- **Options** (`@default_options`): `:guess` (0.1), `:tolerance` (1.0e-9),
  `:max_iterations` (100), `:precision` (6). These defaults mirror the
  spreadsheet `XIRR` standard.

## Testing conventions

- `test/finance_test.exs` keeps the original 0.x numeric cases as **regression
  anchors** — the rewrite reproduces every one of them exactly (e.g.
  `21.118359`, `0.610359`). If you change the day-count basis, rounding, or
  solver, these will shift; that's meaningful, not incidental.
- Correctness is also checked structurally via StreamData properties: recover a
  known rate from a synthetic investment, and assert NPV ≈ 0 at the returned
  rate. Prefer adding a property over hardcoding a hand-computed constant.
- `mix credo --strict` and `mix dialyzer` must stay clean.
