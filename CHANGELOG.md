# Changelog

## Unreleased

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
