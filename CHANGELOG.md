# Changelog

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
