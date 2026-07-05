# Changelog

## 1.3.0 — 2026-07-04

### Added
- `Finance.TVM.ipmt/6` and `ppmt/6` — the interest and principal portions of a
  given period's payment; together they add up to `pmt/5`.
- `Finance.TVM.amortization_schedule/3,4` — the full repayment schedule as a list
  of `%{period, payment, interest, principal, balance}` rows, with the final row
  absorbing rounding so the balance ends at exactly `0`. Computed in integer minor
  units (10^`:precision`), so every row is exact to the requested precision;
  returns `Decimal` rows when given `Decimal` inputs, floats otherwise.
- `Finance.Rates` — `effective_annual_rate/2`, `nominal_rate/2`, and
  `continuous_to_periodic/2` for converting between rate quotations.

## 1.2.0 — 2026-07-04

Reorganised the flat `Finance` module into domain modules. **No behaviour
change** — every function keeps its signature and result.

### Added
- Domain modules: `Finance.CashFlow` (npv/xnpv/irr/xirr/mirr), `Finance.TVM`
  (pv/fv/pmt/nper/rate), `Finance.Depreciation` (sln/syd/ddb/db), and
  `Finance.Returns` (volatility).
- `Finance.Solver` behaviour with the default `Finance.Solver.Newton`. The
  solver is swappable per call with the `:solver` option or globally with
  `config :finance, solver: MySolver` — a seam for a future Nx/GPU solver.

### Deprecated
- The flat `Finance.foo` functions (e.g. `Finance.xirr/1`) now delegate to their
  domain module and are deprecated. They still work in the 1.x line and will be
  removed in 2.0.

## 1.1.0 — 2026-07-04

### Added
- `volatility/2` and `volatility!/2` — annualised volatility of a price series,
  the standard deviation of its period returns scaled by `√periods_per_year`.
  Supports simple or log returns and a configurable period count. Resolves the
  long-standing volatility request (issue #7), with the submitted snippet's
  crashes on short input and zero prices fixed.

## 1.0.0 — 2026-07-04

A complete rewrite of the library. **Breaking changes** — some return values
differ from 0.x because intermediate rounding was removed and the solver was
replaced, and errors are now atoms rather than strings.

### Rate of return
- `xirr/1,2,3` and `xirr!` — internal rate of return for dated cash flows,
  given as `{date, amount}` pairs or two parallel lists. Dates may be `Date`
  structs or `{year, month, day}` tuples.
- `irr/1,2` and `irr!` — internal rate of return for periodic (equally spaced)
  flows.
- `mirr/3,4` and `mirr!` — modified internal rate of return.
- Newton-Raphson solver with an analytic derivative, a bracketing bisection
  fallback, and a hard iteration cap.

### Present / future value
- `xnpv/2,3` and `xnpv!` — net present value of dated cash flows.
- `npv/2,3` and `npv!` — net present value of periodic flows. The first amount
  sits at period 0 (so `npv(irr(a), a) ≈ 0`), which differs from spreadsheet
  `NPV` (first amount at period 1).

### Time value of money
- `fv/5`, `pv/5`, `pmt/5`, `nper/5`, `rate/6` and their `!` variants — solve the
  annuity equation for one unknown, with annuity-due (`type: 1`) support.

### Depreciation
- `sln/3`, `syd/4`, `ddb/5`, `db/5` and their `!` variants — straight-line,
  sum-of-years'-digits, double-declining and fixed-declining depreciation.

### Amounts and options
- Amounts may be integers, floats, or `Decimal` values (via the optional
  `decimal` dependency); results are always floats.
- Options (`:guess`, `:tolerance`, `:max_iterations`, `:precision`) are
  validated with `nimble_options`; unknown keys and out-of-type values raise.

### Removed
- The `timex` runtime dependency (now uses the standard-library `Date`).
- The `spawn_link`-per-cash-flow "parallel" mapping, which was slower and unsafe.

### Tooling
- Requires Elixir `~> 1.18`; tested on Elixir 1.18/OTP 27 and 1.20/OTP 29.
- Travis CI replaced with GitHub Actions.
