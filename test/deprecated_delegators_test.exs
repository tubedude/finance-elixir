# credo:disable-for-this-file Credo.Check.Refactor.Apply
defmodule DeprecatedDelegatorsTest do
  @moduledoc """
  Every deprecated `Finance.*` delegator must return exactly what its new domain
  module returns. `apply/3` is used deliberately to exercise the delegators
  without tripping compile-time deprecation warnings.
  """
  use ExUnit.Case, async: true

  @flows [{~D[2019-01-01], -1000}, {~D[2020-01-01], 1100}]
  @dates [~D[2019-01-01], ~D[2020-01-01]]
  @mirr [-120_000, 39_000, 30_000, 21_000, 37_000, 46_000]

  # {function, args, target module} — one entry per defdelegate.
  @delegations [
    {:xirr, [@flows], Finance.CashFlow},
    {:xirr, [@flows, [precision: 2]], Finance.CashFlow},
    {:xirr, [@dates, [-1000, 1100], []], Finance.CashFlow},
    {:xirr!, [@flows], Finance.CashFlow},
    {:xirr!, [@dates, [-1000, 1100]], Finance.CashFlow},
    {:xnpv, [0.1, @flows], Finance.CashFlow},
    {:xnpv, [0.1, @flows, [precision: 2]], Finance.CashFlow},
    {:xnpv!, [0.1, @flows], Finance.CashFlow},
    {:irr, [[-1000, 1100]], Finance.CashFlow},
    {:irr, [[-1000, 1100], []], Finance.CashFlow},
    {:irr!, [[-1000, 1100]], Finance.CashFlow},
    {:npv, [0.1, [-1000, 1100]], Finance.CashFlow},
    {:npv, [0.1, [-1000, 1100], []], Finance.CashFlow},
    {:npv!, [0.1, [-1000, 1100]], Finance.CashFlow},
    {:mirr, [@mirr, 0.10, 0.12], Finance.CashFlow},
    {:mirr!, [@mirr, 0.10, 0.12], Finance.CashFlow},
    {:fv, [0.05, 10, -100], Finance.TVM},
    {:fv!, [0.05, 10, -100], Finance.TVM},
    {:pv, [0.05, 10, -100], Finance.TVM},
    {:pv!, [0.05, 10, -100], Finance.TVM},
    {:pmt, [0.1, 10, 1000], Finance.TVM},
    {:pmt!, [0.1, 10, 1000], Finance.TVM},
    {:nper, [0.05, -100, 1000], Finance.TVM},
    {:nper!, [0.05, -100, 1000], Finance.TVM},
    {:rate, [10, -100, 1000], Finance.TVM},
    {:rate!, [10, -100, 1000], Finance.TVM},
    {:sln, [10_000, 1_000, 5], Finance.Depreciation},
    {:sln!, [10_000, 1_000, 5], Finance.Depreciation},
    {:syd, [10_000, 1_000, 5, 1], Finance.Depreciation},
    {:syd!, [10_000, 1_000, 5, 1], Finance.Depreciation},
    {:ddb, [10_000, 1_000, 5, 1], Finance.Depreciation},
    {:ddb!, [10_000, 1_000, 5, 1], Finance.Depreciation},
    {:db, [10_000, 1_000, 5, 1], Finance.Depreciation},
    {:db!, [10_000, 1_000, 5, 1], Finance.Depreciation},
    {:volatility, [[100, 102, 101, 103, 105]], Finance.Returns},
    {:volatility!, [[100, 102, 101, 103, 105]], Finance.Returns}
  ]

  for {fun, args, module} <- @delegations do
    test "Finance.#{fun}/#{length(args)} delegates to #{inspect(module)}" do
      assert apply(Finance, unquote(fun), unquote(Macro.escape(args))) ==
               apply(unquote(module), unquote(fun), unquote(Macro.escape(args)))
    end
  end
end
