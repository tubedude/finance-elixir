# Changelog

## Unreleased

### Added
- `xnpv/2,3` and `xnpv!/2` — net present value of dated cash flows.
- `irr/1,2`, `npv/2,3`, `mirr/3,4` and their `!` variants — periodic
  (equally spaced) internal rate of return, net present value, and modified IRR.
- `fv/5`, `pv/5`, `pmt/5`, `nper/5`, `rate/6` and their `!` variants —
  time-value-of-money scalars that solve the annuity equation for one unknown.
- `sln/3`, `syd/4`, `ddb/5`, `db/5` and their `!` variants — straight-line,
  sum-of-years'-digits, double-declining and fixed-declining depreciation.
- Optional `Decimal` support: amounts may be `%Decimal{}` values when the
  (optional) `decimal` dependency is present. Results remain floats.
- Option validation via `nimble_options`: unknown keys and out-of-type values
  now raise `NimbleOptions.ValidationError` (a caller error) instead of being
  silently ignored, and the option docs are generated from the schema.

### Notes
- Periodic `npv/2` places the first amount at period 0 (so `npv(irr(a), a) ≈ 0`),
  which differs from spreadsheet `NPV` (first amount at period 1).

## 1.0.0

Complete rewrite. **Breaking changes** — some return values differ from 0.x
because intermediate rounding was removed and the solver was replaced.

### Added
- `xirr/1` accepting a list of `{date, amount}` cash flows.
- `xirr!/1` and `xirr!/2` bang variants that return the rate or raise.
- Dates may now be `Date` structs or `{year, month, day}` tuples.
- Newton-Raphson solver with an analytic derivative, plus a bracketing
  bisection fallback and a hard iteration cap.

### Changed
- Errors are now atoms (`:mismatched_lengths`, `:insufficient_data`,
  `:single_signed_flow`, `:invalid_date`, `:did_not_converge`) instead of
  English strings.
- Results keep full precision internally and are rounded only once, at the end.

### Removed
- The `timex` runtime dependency — the library is now dependency-free
  (uses the standard-library `Date`).
- The `spawn_link`-per-cash-flow "parallel" mapping, which was slower and
  unsafe. Computation is now sequential.

### Tooling
- Requires Elixir `~> 1.18`; tested on Elixir 1.18/OTP 27 and 1.20/OTP 29.
- Travis CI replaced with GitHub Actions.
