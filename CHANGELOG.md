# Changelog

## 1.6.0 — 2026-07-05

### Added
- `Finance.Solver.Brent` — an alternative solver using Brent's method (bracketing
  secant + inverse-quadratic interpolation + bisection). It uses no derivative, so
  each iteration costs a single NPV evaluation rather than two, which makes it
  faster on long-horizon flows (long amortization schedules, bond ladders) where
  each evaluation is expensive. The default `Finance.Solver.Newton` stays quicker
  on short series, so it remains the default; select Brent with
  `solver: Finance.Solver.Brent` or `config :finance, solver: Finance.Solver.Brent`.

### Fixed
- The rate solvers now find a root when the NPV crosses zero an even number of
  times. Bracketing compared only the two ends of the rate domain, so a series
  with more than one IRR — where both ends share a sign — reported
  `{:error, :did_not_converge}` even though a real rate existed (for example the
  numpy-financial #39 series, which has IRRs near -1.8% and 12%). The bracket now
  scans the interior of the domain, not just its extremes.

### Changed
- For a series with more than one rate, the solver returns the one nearest
  `:guess` (default `0.1`), so a multi-IRR series resolves to the rate a
  guess-driven spreadsheet `XIRR` would return rather than always the lowest.
  Single-rate series are unaffected. Both `Finance.Solver.Newton` and
  `Finance.Solver.Brent` share the bracket, so both select the same root.

## 1.5.1 — 2026-07-05

### Added
- Cash-flow amounts may now be `ex_money` `%Money{}` values, alongside numbers
  and `Decimal`. Finance takes the `Decimal` amount without depending on ex_money,
  and rejects a series that mixes currencies with `{:error, :mixed_currencies}`
  (plain numbers and `Decimal` are currency-neutral and never conflict).

### Changed
- The optional `decimal` requirement is relaxed to `~> 2.0 or ~> 3.0`, so finance
  can share a project with libraries pinned to Decimal 2.x — ex_money among them.

## 1.5.0 — 2026-07-05

### Added
- `Finance.CashFlow.irr_many/2` and `xirr_many/2` — solve a whole batch of
  independent series in one call, returning a list of `{:ok, rate}` /
  `{:error, reason}` in the same order (one bad series doesn't sink the batch).
  They run on the configured solver: the default pure-Elixir solver parallelizes
  across schedulers with `Task.async_stream`, while a native (Rustler) or Nx
  backend can run the whole batch in a single call.
- `Finance.Solver` gains a `solve_many/2` callback for that batch seam.

### Changed
- Custom `Finance.Solver` implementations must now provide `solve_many/2`
  alongside `solve/2`. The shipped `Finance.Solver.Newton` implements it (the
  parallel default), so the built-in behaviour is unchanged.

### Fixed
- `finance` now compiles when the optional `decimal` dependency is absent.
  Two functions matched `%Decimal{}` in their head, and a struct pattern is
  resolved at compile time — so a consumer who depended on `finance` without also
  adding `decimal` hit `struct Decimal is undefined` at compile. The two heads now
  use `is_struct(value, Decimal)` guards (runtime, no compile-time module needed),
  so the Decimal support is genuinely optional. Behaviour with `decimal` present
  is unchanged.
- The solver now converges over very long horizons that a high-rate probe would
  overflow. Bracketing evaluates the NPV at rate `1.0`, where `(1 + 1)^t`
  overflows once `t` is large (e.g. a 2000-period flow) — and Erlang's
  `:math.pow` raises on overflow, which aborted the whole solve to
  `:did_not_converge`. `present_value` and the solver's derivative now discount
  with a negative exponent (`amount * (1 + rate)^-t`), so the factor underflows
  to a negligible `0` instead of overflowing. Results for normal flows are
  unchanged.

## 1.4.3 — 2026-07-05

### Changed
- The default solver is now a safeguarded Newton (the classic `rtsafe`): it
  brackets the root, then each step takes a Newton step when that step lands
  inside the bracket and is converging fast enough, and a bisection step
  otherwise — all in one pass, rather than running Newton to exhaustion and then
  bisecting separately. Results are unchanged, but long-horizon flows are much
  faster (a 480-period loan's `rate` solves ~9× quicker), and because the
  maintained bracket always encloses a sign change the solver can no longer
  return a stalled non-root. The bracket-membership test compares the Newton
  point against the bracket instead of multiplying two net present values, which
  would overflow in the steep zone near the bracket's floor for long-dated flows.

## 1.4.2 — 2026-07-05

### Fixed
- The rate solver no longer reports a non-root as converged. Newton's step-size
  termination could accept a rate where the NPV was still large — near a steep
  NPV the step `f / f'` shrinks below the tolerance even while `f` does not — so
  convergence now rests solely on the NPV threshold, and a stalled Newton falls
  through to bisection.
- `amortization_schedule` keeps the balance retiring monotonically within
  `[0, opening]`. Once `(1 + rate)^nper` is large a cent-rounded level payment
  can no longer tame the balance: rounded a hair high it overshot below zero,
  a hair low it grew the balance back (negative amortization) before the final
  row absorbed the difference. Each period now clamps so the schedule stays
  monotonic and bounded, with a final row that clears whatever remains.

### Added
- Property-based stress tests for the solver and TVM: IRR root-finding across
  extreme rates and long horizons, a no-crash / real-root contract on arbitrary
  cash-flow signs, `TVM.rate` round-trips, `pv`/`fv` inversion, and amortization
  balance invariants. These surfaced the two fixes above.

## 1.4.1 — 2026-07-05

### Fixed
- The solver now converges for long-maturity, low-rate flows — for example the
  `ytm` of a deep-discount 28-year bond, or a 30-year monthly amortization
  `rate`. Previously a Newton step could overflow on such flows and abort the
  whole solve instead of falling through to bisection, and the bisection bracket
  itself overflowed for long-dated flows. Now a Newton overflow falls through to
  bisection, the bracket floor adapts to the longest flow, and the bracketing
  sign check compares signs instead of multiplying (which could overflow).

## 1.4.0 — 2026-07-04

### Added
- `Finance.Returns` return metrics: `cagr/4` (compound annual growth rate),
  `payback_period/2` and `discounted_payback_period/3` (with fractional-period
  interpolation), `profitability_index/3` (reusing `CashFlow.npv`), and `twr/2`
  (time-weighted return, with an optional `:periods_per_year` to annualise) —
  each with a `!` variant.

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
- `Finance.Bonds` — fixed income: `price/5`, `ytm/5` (reuses the `Finance.Solver`
  seam, mirroring `TVM.rate`), `duration/4` (Macaulay), `modified_duration/4`,
  and `convexity/4`, each with a `!` variant. Maturity is given in years with a
  configurable coupon frequency (`freq`, default `2`); settlement is assumed to
  fall on a coupon date (clean price, no accrued interest).

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
