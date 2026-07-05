defmodule StubSolver do
  @moduledoc false
  @behaviour Finance.Solver
  @impl true
  def solve(_flows, _opts), do: {:ok, 0.42}
  @impl true
  def solve_many(batch, _opts), do: Enum.map(batch, fn _ -> {:ok, 0.42} end)
end

defmodule FinanceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Finance.CashFlow
  doctest Finance.TVM
  doctest Finance.Depreciation
  doctest Finance.Returns
  doctest Finance.Rates
  doctest Finance.Bonds

  describe "module organization" do
    test "the solver is swappable via the :solver option" do
      assert Finance.CashFlow.irr([-1000, 1100], solver: StubSolver) == {:ok, 0.42}
      assert Finance.TVM.rate(10, -100, 1000, 0.0, 0, solver: StubSolver) == {:ok, 0.42}
    end

    test "batch functions dispatch through the solver's solve_many" do
      assert Finance.CashFlow.irr_many([[-1000, 1100], [-1000, 1200]], solver: StubSolver) ==
               [{:ok, 0.42}, {:ok, 0.42}]
    end

    test "the shared options docs are generated from the schema" do
      docs = Finance.Shared.options_docs()
      assert is_binary(docs)
      assert docs =~ ":guess"
    end
  end

  describe "xirr/2 regression cases" do
    test "very good investment" do
      d = [{2015, 11, 1}, {2015, 10, 1}, {2015, 6, 1}]
      v = [-800_000, -2_200_000, 1_000_000]
      assert Finance.CashFlow.xirr(d, v) == {:ok, 21.118359}
    end

    test "bad investment" do
      d = [{1985, 1, 1}, {1990, 1, 1}, {1995, 1, 1}]
      v = [1000, -600, -200]
      assert Finance.CashFlow.xirr(d, v) == {:ok, -0.034592}
    end

    test "marano" do
      d = [{2014, 11, 7}, {2015, 5, 6}]
      v = [900, -13.5]
      assert Finance.CashFlow.xirr(d, v) == {:ok, -0.9998}
    end

    test "xichen27" do
      d = [{2014, 4, 15}, {2014, 5, 15}, {2014, 10, 19}]
      v = [-10_000.0, 305.6, 500.0]
      assert Finance.CashFlow.xirr(d, v) == {:ok, -0.996815}
    end

    test "repeated cashflow on the same date is combined" do
      v = [1000.0, 2000.0, -2000.0, -4000.0]
      d = [{2011, 12, 7}, {2011, 12, 7}, {2013, 5, 21}, {2013, 5, 21}]
      assert Finance.CashFlow.xirr(d, v) == {:ok, 0.610359}
    end

    test "ok investment" do
      v = [1000.0, -600.0, -6000.0]
      d = [{1985, 1, 1}, {1990, 1, 1}, {1995, 1, 1}]
      assert Finance.CashFlow.xirr(d, v) == {:ok, 0.225683}
    end

    test "sign of the whole series does not matter" do
      d = [{1985, 1, 1}, {1990, 1, 1}, {1995, 1, 1}]

      assert Finance.CashFlow.xirr(d, [1000.0, -600.0, -6000.0]) ==
               Finance.CashFlow.xirr(d, [-1000.0, 600.0, 6000.0])
    end
  end

  describe "input shapes" do
    test "accepts {date, amount} pairs" do
      assert Finance.CashFlow.xirr([{~D[2019-01-01], -1000}, {~D[2020-01-01], 1100}]) ==
               {:ok, 0.1}
    end

    test "accepts Date structs and {y, m, d} tuples interchangeably" do
      pairs = Finance.CashFlow.xirr([{~D[2019-01-01], -1000}, {~D[2020-01-01], 1100}])
      tuples = Finance.CashFlow.xirr([{2019, 1, 1}, {2020, 1, 1}], [-1000, 1100])
      assert pairs == tuples
    end

    test "xirr!/2 returns the bare rate" do
      assert Finance.CashFlow.xirr!([{2019, 1, 1}, {2020, 1, 1}], [-1000, 1100]) == 0.1
    end

    test "xirr!/1 raises on error" do
      assert_raise ArgumentError, fn -> Finance.CashFlow.xirr!([{~D[2020-01-01], 100}]) end
    end
  end

  describe "options" do
    test ":precision controls rounding of the result" do
      flows = [{~D[2019-01-01], -1000}, {~D[2020-01-01], 1100}]
      assert Finance.CashFlow.xirr(flows, precision: 2) == {:ok, 0.1}
      assert {:ok, rate} = Finance.CashFlow.xirr(flows, precision: 10)
      assert_in_delta rate, 0.1, 1.0e-6
    end

    test ":guess still converges to the same rate" do
      flows = [
        {~D[2015-06-01], 1_000_000},
        {~D[2015-10-01], -2_200_000},
        {~D[2015-11-01], -800_000}
      ]

      assert Finance.CashFlow.xirr(flows, guess: 5.0) == Finance.CashFlow.xirr(flows)
    end

    test "options work with the two-list form via xirr/3" do
      assert Finance.CashFlow.xirr([{2019, 1, 1}, {2020, 1, 1}], [-1000, 1100], precision: 3) ==
               {:ok, 0.1}
    end

    test "an unknown option key raises (caller error, not a data error)" do
      flows = [{~D[2019-01-01], -1000}, {~D[2020-01-01], 1100}]

      assert_raise NimbleOptions.ValidationError, fn ->
        Finance.CashFlow.xirr(flows, precison: 2)
      end
    end

    test "an out-of-type option value raises" do
      assert_raise NimbleOptions.ValidationError, fn ->
        Finance.CashFlow.irr([-1000, 1100], max_iterations: -5)
      end

      assert_raise NimbleOptions.ValidationError, fn ->
        Finance.CashFlow.npv(0.1, [-1000, 1100], precision: 1.5)
      end
    end
  end

  describe "errors" do
    test "mismatched list lengths" do
      assert Finance.CashFlow.xirr([{2014, 4, 15}, {2014, 10, 19}], [-10_000.0, 305.6, 500.0]) ==
               {:error, :mismatched_lengths}
    end

    test "all amounts the same sign" do
      assert Finance.CashFlow.xirr([{2014, 4, 15}, {2014, 10, 19}], [305.6, 500.0]) ==
               {:error, :single_signed_flow}
    end

    test "positive and negative flow on the same day cancel out" do
      d = [{2014, 4, 15}, {2014, 4, 15}, {2014, 10, 19}]
      v = [-10_000.0, 10_000.0, 500.0]
      assert Finance.CashFlow.xirr(d, v) == {:error, :single_signed_flow}
    end

    test "a series that cannot converge" do
      v = [
        105_187.06,
        816_709.66,
        479_069.684,
        937_309.708,
        88_622.661,
        100_000.0,
        80_000.0,
        403_627.95,
        508_117.9,
        789_706.87,
        -88_622.661,
        -789_706.871,
        -688_117.9,
        -403_627.95,
        403_627.95,
        789_706.871,
        88_622.661,
        688_117.9,
        45_129.14,
        26_472.08,
        51_793.2,
        126_605.59,
        278_532.29,
        99_284.1,
        58_238.57,
        113_945.03,
        405_137.88,
        -405_137.88,
        165_738.23,
        -165_738.23,
        144_413.24,
        84_710.65,
        -84_710.65,
        -144_413.24
      ]

      d = [
        {2011, 12, 7},
        {2011, 12, 7},
        {2011, 12, 7},
        {2012, 1, 18},
        {2012, 7, 3},
        {2012, 7, 3},
        {2012, 7, 19},
        {2012, 7, 23},
        {2012, 7, 23},
        {2012, 7, 23},
        {2012, 9, 11},
        {2012, 9, 11},
        {2012, 9, 11},
        {2012, 9, 11},
        {2012, 9, 12},
        {2012, 9, 12},
        {2012, 9, 12},
        {2012, 9, 12},
        {2013, 3, 11},
        {2013, 3, 11},
        {2013, 3, 11},
        {2013, 3, 11},
        {2013, 3, 28},
        {2013, 3, 28},
        {2013, 3, 28},
        {2013, 3, 28},
        {2013, 5, 21},
        {2013, 5, 21},
        {2013, 5, 21},
        {2013, 5, 21},
        {2013, 5, 21},
        {2013, 5, 21},
        {2013, 5, 21},
        {2013, 5, 21}
      ]

      assert Finance.CashFlow.xirr(d, v) == {:error, :did_not_converge}
    end

    test "empty input" do
      assert Finance.CashFlow.xirr([]) == {:error, :insufficient_data}
    end

    test "an invalid date is reported" do
      flows = [{{2019, 13, 1}, -100}, {{2019, 1, 1}, 100}]
      assert Finance.CashFlow.xirr(flows) == {:error, :invalid_date}
    end
  end

  describe "solver bracketing" do
    # A single safeguarded step still returns the bracketed estimate rather than
    # erroring, so a starved solver yields a value when a root is bracketed.
    test "returns a value when a root is bracketed" do
      assert {:ok, _rate} = Finance.CashFlow.irr([-1000, 500, 500, 300], max_iterations: 1)
    end

    test "diverges when no root can be bracketed" do
      # An all-positive series has no rate; the bracket expands, finds no sign
      # change, and the solver gives up.
      assert Finance.TVM.rate(10, 100, 1000, 0.0, 0, max_iterations: 1) ==
               {:error, :did_not_converge}
    end

    test "a guess outside the bracket falls back to the midpoint and still converges" do
      assert Finance.CashFlow.irr([-1000, 1100], guess: 5.0) == {:ok, 0.1}
    end

    test "magnitudes that overflow the discounting are reported, not raised" do
      # Near the bracket floor, discounting a ~1e308 flow overflows; the solver
      # treats that as a failure to converge rather than crashing the caller.
      assert Finance.CashFlow.irr([1.0e308, -1.0e308]) == {:error, :did_not_converge}
    end

    test "converges on long-dated flows whose steep NPV would overflow a naive step" do
      # A 471-period loan puts the bracket floor deep enough that the NPV near it
      # is ~1e290; the safeguarded step must compare the Newton point against the
      # bracket rather than multiply those magnitudes (which overflows).
      {:ok, pv} = Finance.TVM.pv(0.011, 471, -1, 0.0, 0)
      assert {:ok, rate} = Finance.TVM.rate(471, -1, pv, 0.0, 0, precision: 10)
      assert_in_delta rate, 0.011, 1.0e-6
    end

    test "converges over very long horizons where a high-rate probe would overflow" do
      # Bracketing probes the NPV at rate 1.0; over 2000 periods `2^2000` overflows.
      # Discounting with a negative exponent underflows to 0 there instead of
      # raising, so the solve still finds the (small) root.
      {:ok, pv} = Finance.TVM.pv(0.002, 2000, -1, 0.0, 0)
      assert {:ok, rate} = Finance.TVM.rate(2000, -1, pv, 0.0, 0, precision: 10)
      assert_in_delta rate, 0.002, 1.0e-6
    end
  end

  describe "Finance.Solver.Brent (alternative solver)" do
    test "reproduces the xirr regression anchors" do
      assert Finance.CashFlow.xirr(
               [{2015, 11, 1}, {2015, 10, 1}, {2015, 6, 1}],
               [-800_000, -2_200_000, 1_000_000],
               solver: Finance.Solver.Brent
             ) == {:ok, 21.118359}

      assert Finance.CashFlow.irr([-1000, 500, 500, 300], solver: Finance.Solver.Brent) ==
               {:ok, 0.156579}
    end

    test "matches the default solver across a spread of loans, including long/steep" do
      for rate_bp <- [10, 100, 500, 1200, 3000], nper <- [12, 60, 180, 480, 2000] do
        rate = rate_bp / 10_000
        pmt = -(100_000 * rate / (1 - :math.pow(1 + rate, -nper)))
        assert {:ok, default} = Finance.TVM.rate(nper, pmt, 100_000, 0.0, 0, precision: 10)

        assert {:ok, brent} =
                 Finance.TVM.rate(nper, pmt, 100_000, 0.0, 0,
                   precision: 10,
                   solver: Finance.Solver.Brent
                 )

        # Two different algorithms converge to points differing below the solver
        # tolerance, so compare within it rather than demanding bit-identity.
        assert_in_delta brent, default, 1.0e-7, "mismatch at rate_bp=#{rate_bp} nper=#{nper}"
      end
    end

    test "reports :did_not_converge when no root can be bracketed" do
      assert Finance.TVM.rate(10, 100, 1000, 0.0, 0, solver: Finance.Solver.Brent) ==
               {:error, :did_not_converge}
    end

    test "a starved iteration budget still returns the bracketed estimate" do
      assert {:ok, _rate} =
               Finance.CashFlow.irr([-1000, 500, 500, 300],
                 solver: Finance.Solver.Brent,
                 max_iterations: 1
               )
    end

    test "magnitudes that overflow the discounting are reported, not raised" do
      assert Finance.CashFlow.irr([1.0e308, -1.0e308], solver: Finance.Solver.Brent) ==
               {:error, :did_not_converge}
    end

    test "collapses a negative zero like the default" do
      # A series whose rate is exactly 0 (10 payments of 100 repay 1000).
      assert Finance.TVM.rate(10, -100, 1000, 0.0, 0, solver: Finance.Solver.Brent) == {:ok, 0.0}
    end

    test "batches through solve_many, matching the default" do
      series = [[-1000, 1100], [-1000, 500, 500, 300], [100, 200], [-500, 250, 250, 100]]

      assert Finance.CashFlow.irr_many(series, solver: Finance.Solver.Brent) ==
               Finance.CashFlow.irr_many(series)
    end
  end

  describe "batch — irr_many/xirr_many" do
    test "irr_many matches mapping irr over the series" do
      series = [[-1000, 1100], [-1000, 500, 500, 300], [-500, 200, 200, 200]]
      assert Finance.CashFlow.irr_many(series) == Enum.map(series, &Finance.CashFlow.irr/1)
    end

    test "a batch larger than the chunk count keeps order and results" do
      # Spans several chunks, with a distinct rate per series so order matters.
      series = for i <- 1..100, do: [-1000, 1000 + i]
      assert Finance.CashFlow.irr_many(series) == Enum.map(series, &Finance.CashFlow.irr/1)
    end

    test "xirr_many matches mapping xirr over the series" do
      series = [
        [{~D[2019-01-01], -1000}, {~D[2020-01-01], 1100}],
        [{~D[2019-01-01], -1000}, {~D[2020-01-01], 1200}]
      ]

      assert Finance.CashFlow.xirr_many(series) == Enum.map(series, &Finance.CashFlow.xirr/1)
    end

    test "a bad series returns its error without sinking the batch, order preserved" do
      series = [[-1000, 1100], [100, 200], []]

      assert Finance.CashFlow.irr_many(series) ==
               [{:ok, 0.1}, {:error, :single_signed_flow}, {:error, :insufficient_data}]
    end

    test "an invalid date in one dated series only fails that series" do
      series = [
        [{~D[2019-01-01], -1000}, {~D[2020-01-01], 1100}],
        [{{2019, 13, 1}, -1000}, {~D[2020-01-01], 1100}]
      ]

      assert Finance.CashFlow.xirr_many(series) == [{:ok, 0.1}, {:error, :invalid_date}]
    end

    test "an empty batch is an empty list" do
      assert Finance.CashFlow.irr_many([]) == []
      assert Finance.CashFlow.xirr_many([]) == []
    end

    test "options apply to every series in the batch" do
      assert Finance.CashFlow.irr_many([[-1000, 1100]], precision: 2) == [{:ok, 0.1}]
    end
  end

  describe "xnpv/2" do
    test "discounts a single future flow" do
      flows = [{~D[2019-01-01], -1000}, {~D[2020-01-01], 1000}]
      assert Finance.CashFlow.xnpv(0.1, flows) == {:ok, -90.909091}
    end

    test "does not require a sign change" do
      flows = [{~D[2019-01-01], 500}, {~D[2020-01-01], 500}]
      assert {:ok, value} = Finance.CashFlow.xnpv(0.1, flows)
      assert_in_delta value, 500 + 500 / 1.1, 1.0e-6
    end

    test ":precision controls rounding" do
      flows = [{~D[2019-01-01], -1000}, {~D[2020-01-01], 1000}]
      assert {:ok, value} = Finance.CashFlow.xnpv(0.1, flows, precision: 2)
      assert value == -90.91
    end

    test "combines flows on the same date" do
      flows = [{~D[2019-01-01], -1000}, {~D[2019-01-01], 400}, {~D[2020-01-01], 1000}]
      assert Finance.CashFlow.xnpv(0.1, flows) == {:ok, 309.090909}
    end

    test "propagates normalization errors" do
      assert Finance.CashFlow.xnpv(0.1, []) == {:error, :insufficient_data}
    end

    test "xnpv!/2 returns the bare value and raises on error" do
      assert Finance.CashFlow.xnpv!(0.1, [{~D[2019-01-01], -1000}, {~D[2020-01-01], 1100}]) == 0.0
      assert_raise ArgumentError, fn -> Finance.CashFlow.xnpv!(0.1, []) end
    end
  end

  describe "irr/1 (periodic)" do
    test "simple two-flow investment" do
      assert Finance.CashFlow.irr([-1000, 1100]) == {:ok, 0.1}
    end

    test "matches xirr on equally spaced annual dates" do
      # Non-leap consecutive years give exactly one-year periods.
      dates = [~D[2001-01-01], ~D[2002-01-01], ~D[2003-01-01], ~D[2004-01-01]]
      amounts = [-1000, 500, 500, 300]
      assert Finance.CashFlow.irr(amounts) == Finance.CashFlow.xirr(dates, amounts)
    end

    test "requires at least one positive and one negative amount" do
      assert Finance.CashFlow.irr([100, 200, 300]) == {:error, :single_signed_flow}
      assert Finance.CashFlow.irr([-500]) == {:error, :insufficient_data}
    end

    test "irr!/1 returns the bare rate and raises on error" do
      assert Finance.CashFlow.irr!([-1000, 1100]) == 0.1
      assert_raise ArgumentError, fn -> Finance.CashFlow.irr!([1, 2, 3]) end
    end
  end

  describe "npv/2 (periodic)" do
    test "first amount sits at period 0 (undiscounted)" do
      # -1000 + 600/1.1 + 600/1.1^2
      assert Finance.CashFlow.npv(0.1, [-1000, 600, 600]) == {:ok, 41.322314}
    end

    test "npv at the irr rate is ~zero" do
      amounts = [-1000, 500, 500, 300]
      assert {:ok, rate} = Finance.CashFlow.irr(amounts)
      assert {:ok, value} = Finance.CashFlow.npv(rate, amounts)
      assert_in_delta value, 0.0, 1.0e-3
    end

    test "empty series is an error" do
      assert Finance.CashFlow.npv(0.1, []) == {:error, :insufficient_data}
    end

    test "npv!/2 returns the bare value" do
      assert Finance.CashFlow.npv!(0.1, [-1000, 1100]) == 0.0
    end
  end

  describe "mirr/3" do
    test "Microsoft's documented example" do
      values = [-120_000, 39_000, 30_000, 21_000, 37_000, 46_000]
      assert Finance.CashFlow.mirr(values, 0.10, 0.12) == {:ok, 0.126094}
    end

    test "requires both an inflow and an outflow" do
      assert Finance.CashFlow.mirr([100, 200], 0.1, 0.1) == {:error, :single_signed_flow}
      assert Finance.CashFlow.mirr([-100], 0.1, 0.1) == {:error, :insufficient_data}
    end

    test "mirr!/3 returns the bare rate" do
      values = [-120_000, 39_000, 30_000, 21_000, 37_000, 46_000]
      assert Finance.CashFlow.mirr!(values, 0.10, 0.12) == 0.126094
    end
  end

  describe "Decimal amounts (optional dependency)" do
    test "xirr accepts Decimal amounts, matching float results" do
      decimals = [{~D[2019-01-01], Decimal.new("-1000")}, {~D[2020-01-01], Decimal.new("1100")}]
      floats = [{~D[2019-01-01], -1000.0}, {~D[2020-01-01], 1100.0}]
      assert Finance.CashFlow.xirr(decimals) == Finance.CashFlow.xirr(floats)
      assert Finance.CashFlow.xirr(decimals) == {:ok, 0.1}
    end

    test "periodic functions accept Decimal amounts" do
      assert Finance.CashFlow.irr([Decimal.new("-1000"), Decimal.new("1100")]) == {:ok, 0.1}

      assert Finance.CashFlow.mirr(
               [Decimal.new("-100"), Decimal.new("50"), Decimal.new("80")],
               0.1,
               0.1
             ) ==
               Finance.CashFlow.mirr([-100, 50, 80], 0.1, 0.1)
    end
  end

  describe "ex_money amounts (optional)" do
    test "accepts %Money{} amounts, matching the numeric result" do
      dated = [{~D[2019-01-01], money(:USD, "-1000")}, {~D[2020-01-01], money(:USD, "1100")}]
      assert Finance.CashFlow.xirr(dated) == {:ok, 0.1}
      assert Finance.CashFlow.irr([money(:USD, "-1000"), money(:USD, "1100")]) == {:ok, 0.1}
      assert Finance.CashFlow.npv(0.1, [money(:USD, "-1000"), money(:USD, "1100")]) == {:ok, 0.0}
    end

    test "a plain number alongside Money is currency-neutral and allowed" do
      assert Finance.CashFlow.irr([money(:USD, "-1000"), 1100]) == {:ok, 0.1}
    end

    test "mixing currencies is rejected across the functions" do
      assert Finance.CashFlow.irr([money(:USD, "-1000"), money(:EUR, "1100")]) ==
               {:error, :mixed_currencies}

      dated = [{~D[2019-01-01], money(:USD, "-1000")}, {~D[2020-01-01], money(:EUR, "1100")}]
      assert Finance.CashFlow.xirr(dated) == {:error, :mixed_currencies}
      assert Finance.CashFlow.xnpv(0.1, dated) == {:error, :mixed_currencies}

      assert Finance.CashFlow.npv(0.1, [money(:USD, "-1000"), money(:EUR, "1100")]) ==
               {:error, :mixed_currencies}

      assert Finance.CashFlow.mirr(
               [money(:USD, "-100"), money(:EUR, "50"), money(:USD, "80")],
               0.1,
               0.1
             ) ==
               {:error, :mixed_currencies}
    end

    test "batch functions reject mixed currencies per series" do
      series = [
        [money(:USD, "-1000"), money(:USD, "1100")],
        [money(:USD, "-1000"), money(:EUR, "1100")]
      ]

      assert Finance.CashFlow.irr_many(series) == [{:ok, 0.1}, {:error, :mixed_currencies}]
    end
  end

  describe "TVM scalars" do
    test "fv, pv, pmt, nper are mutually consistent" do
      # A payment that pays off pv over nper periods should give fv ~ 0.
      assert {:ok, payment} = Finance.TVM.pmt(0.10, 10, 1000)
      assert_in_delta payment, -162.745395, 1.0e-6
      assert {:ok, future} = Finance.TVM.fv(0.10, 10, payment, 1000)
      assert_in_delta future, 0.0, 1.0e-4
    end

    test "pv inverts fv" do
      assert {:ok, future} = Finance.TVM.fv(0.08, 5, 0, -1000)
      assert {:ok, present} = Finance.TVM.pv(0.08, 5, 0, future)
      assert_in_delta present, -1000.0, 1.0e-6
    end

    test "nper inverts pmt" do
      assert {:ok, payment} = Finance.TVM.pmt(0.05, 12, 1000)
      assert {:ok, periods} = Finance.TVM.nper(0.05, payment, 1000)
      assert_in_delta periods, 12.0, 1.0e-6
    end

    test "rate inverts pmt (reuses the irr solver)" do
      assert {:ok, payment} = Finance.TVM.pmt(0.03, 24, 5000)
      assert Finance.TVM.rate(24, payment, 5000) == {:ok, 0.03}
    end

    test "zero-rate branches" do
      assert Finance.TVM.fv(0.0, 10, -100, 0) == {:ok, 1000.0}
      assert Finance.TVM.pv(0.0, 10, -100, 0) == {:ok, 1000.0}
      assert Finance.TVM.pmt(0.0, 10, 1000) == {:ok, -100.0}
      assert Finance.TVM.nper(0.0, -100, 1000) == {:ok, 10.0}
    end

    test "type: 1 (annuity due) differs from ordinary" do
      assert {:ok, ordinary} = Finance.TVM.fv(0.05, 10, -100, 0, 0)
      assert {:ok, due} = Finance.TVM.fv(0.05, 10, -100, 0, 1)
      # Paying at the start of each period earns one extra period of interest.
      assert_in_delta due, ordinary * 1.05, 1.0e-6
    end

    test "undefined and non-convergent cases" do
      assert Finance.TVM.pmt(0.05, 0, 1000) == {:error, :undefined}
      assert Finance.TVM.nper(0.0, 0, 1000) == {:error, :undefined}
      assert Finance.TVM.rate(10.5, -100, 1000) == {:error, :undefined}
    end

    test "bang variants return bare values and raise" do
      assert Finance.TVM.fv!(0.0, 10, -100, 0) == 1000.0
      assert Finance.TVM.pv!(0.0, 10, -100, 0) == 1000.0
      assert Finance.TVM.pmt!(0.0, 10, 1000) == -100.0
      assert Finance.TVM.nper!(0.0, -100, 1000) == 10.0
      assert Finance.TVM.rate!(10, -100, 1000) == 0.0
      assert_raise ArgumentError, fn -> Finance.TVM.pmt!(0.05, 0, 1000) end
      assert_raise ArgumentError, fn -> Finance.TVM.rate!(10, 100, 1000) end
    end

    test "rate with a single-signed series cannot converge" do
      assert Finance.TVM.rate(10, 100, 1000) == {:error, :did_not_converge}
    end

    test "nper is undefined when 1 + rate <= 0" do
      assert Finance.TVM.nper(-1.5, -100, 1000) == {:error, :undefined}
    end

    test "nper is undefined when the payment exactly services the balance" do
      # pmt/rate cancels pv, so the log argument's denominator is zero.
      assert Finance.TVM.nper(0.05, -50, 1000) == {:error, :undefined}
    end

    test "rate handles annuity-due (type: 1)" do
      assert {:ok, _rate} = Finance.TVM.rate(10, -100, 1000, 0.0, 1)
    end

    test "invalid options still raise through rate/6" do
      assert_raise NimbleOptions.ValidationError, fn ->
        Finance.TVM.rate(10, -100, 1000, 0.0, 0, precision: -1)
      end
    end
  end

  describe "depreciation" do
    test "straight-line spreads the loss evenly" do
      assert Finance.Depreciation.sln(10_000, 1_000, 5) == {:ok, 1800.0}
      assert Finance.Depreciation.sln(10_000, 1_000, 0) == {:error, :undefined}
      assert Finance.Depreciation.sln!(10_000, 1_000, 5) == 1800.0
    end

    test "sum-of-years'-digits accelerates then tapers" do
      assert Finance.Depreciation.syd(10_000, 1_000, 5, 1) == {:ok, 3000.0}
      assert Finance.Depreciation.syd(10_000, 1_000, 5, 5) == {:ok, 600.0}
      # The four remaining years plus the first sum to the depreciable base.
      total =
        for(p <- 1..5, do: elem(Finance.Depreciation.syd(10_000, 1_000, 5, p), 1)) |> Enum.sum()

      assert_in_delta total, 9000.0, 1.0e-9
    end

    test "syd rejects out-of-range and non-positive life" do
      assert Finance.Depreciation.syd(10_000, 1_000, 5, 6) == {:error, :undefined}
      assert Finance.Depreciation.syd(10_000, 1_000, 5, 0) == {:error, :undefined}
      assert Finance.Depreciation.syd(10_000, 1_000, 0, 1) == {:error, :undefined}
      assert_raise ArgumentError, fn -> Finance.Depreciation.syd!(10_000, 1_000, 5, 6) end
    end

    test "double-declining balance never drops below salvage and sums to the base" do
      assert Finance.Depreciation.ddb(10_000, 1_000, 5, 1) == {:ok, 4000.0}
      assert Finance.Depreciation.ddb(10_000, 1_000, 5, 5) == {:ok, 296.0}

      total =
        for(p <- 1..5, do: elem(Finance.Depreciation.ddb(10_000, 1_000, 5, p), 1)) |> Enum.sum()

      assert_in_delta total, 9000.0, 1.0e-9
    end

    test "ddb honours a custom factor and rejects invalid input" do
      assert {:ok, value} = Finance.Depreciation.ddb(10_000, 1_000, 5, 1, 3)
      assert value == 6000.0
      assert Finance.Depreciation.ddb(10_000, 1_000, 0, 1) == {:error, :undefined}
      assert Finance.Depreciation.ddb(10_000, 1_000, 5, 2.5) == {:error, :undefined}
      assert Finance.Depreciation.ddb(10_000, 1_000, 5, 6) == {:error, :undefined}
      assert Finance.Depreciation.ddb!(10_000, 1_000, 5, 1) == 4000.0
    end

    test "fixed-declining balance with a full first year" do
      assert Finance.Depreciation.db(10_000, 1_000, 5, 1) == {:ok, 3690.0}
      assert Finance.Depreciation.db(10_000, 1_000, 5, 2) == {:ok, 2328.39}
      assert Finance.Depreciation.db!(10_000, 1_000, 5, 1) == 3690.0
    end

    test "db with a short first year has a partial final period" do
      assert {:ok, first} = Finance.Depreciation.db(10_000, 1_000, 5, 1, 6)
      # First-year depreciation is prorated to 6 months.
      assert_in_delta first, 10_000 * 0.369 * 6 / 12, 1.0e-9
      assert {:ok, last} = Finance.Depreciation.db(10_000, 1_000, 5, 6, 6)
      assert last > 0
    end

    test "db rejects invalid input" do
      assert Finance.Depreciation.db(0, 1_000, 5, 1) == {:error, :undefined}
      assert Finance.Depreciation.db(10_000, 1_000, 5, 1, 13) == {:error, :undefined}
      assert Finance.Depreciation.db(10_000, 1_000, 5, 2.5) == {:error, :undefined}
    end
  end

  describe "Finance.Returns metrics" do
    test "cagr" do
      assert Finance.Returns.cagr(1000, 2000, 10) == {:ok, 0.071773}
      assert Finance.Returns.cagr(1000, 1000, 5) == {:ok, 0.0}
      assert Finance.Returns.cagr(-1000, 2000, 10) == {:error, :undefined}
      assert Finance.Returns.cagr(1000, 2000, 0) == {:error, :undefined}
      assert Finance.Returns.cagr(1000, -2000, 10) == {:error, :undefined}
      assert Finance.Returns.cagr!(1000, 2000, 10) == 0.071773
      assert_raise ArgumentError, fn -> Finance.Returns.cagr!(1000, 2000, 0) end
    end

    test "payback_period interpolates and reports undefined/empty" do
      assert Finance.Returns.payback_period([-1000, 500, 500, 500]) == {:ok, 2.0}
      assert Finance.Returns.payback_period([-1000, 400, 400, 400]) == {:ok, 2.5}
      assert Finance.Returns.payback_period([-1000, 100, 100]) == {:error, :undefined}
      assert Finance.Returns.payback_period([1000, 400]) == {:error, :undefined}
      assert Finance.Returns.payback_period([]) == {:error, :insufficient_data}
      assert Finance.Returns.payback_period!([-1000, 400, 400, 400]) == 2.5
    end

    test "discounted_payback_period" do
      assert Finance.Returns.discounted_payback_period([-1000, 600, 600, 600], 0.1) ==
               {:ok, 1.916667}

      # at rate 0 it matches the plain payback
      assert Finance.Returns.discounted_payback_period([-1000, 600, 600, 600], 0.0) ==
               Finance.Returns.payback_period([-1000, 600, 600, 600])

      assert Finance.Returns.discounted_payback_period([-1000, 100, 100], 0.1) ==
               {:error, :undefined}

      assert Finance.Returns.discounted_payback_period!([-1000, 600, 600, 600], 0.1) == 1.916667
    end

    test "profitability_index reuses npv" do
      assert Finance.Returns.profitability_index([-1000, 600, 600], 0.1) == {:ok, 1.041322}
      assert Finance.Returns.profitability_index([-1000, 1100], 0.1) == {:ok, 1.0}
      assert Finance.Returns.profitability_index([1000, 600], 0.1) == {:error, :undefined}
      assert Finance.Returns.profitability_index([], 0.1) == {:error, :insufficient_data}
      assert Finance.Returns.profitability_index!([-1000, 600, 600], 0.1) == 1.041322
    end

    test "twr links returns geometrically, optionally annualised" do
      assert Finance.Returns.twr([0.10, -0.05, 0.08]) == {:ok, 0.1286}
      assert Finance.Returns.twr([0.0, 0.0]) == {:ok, 0.0}
      assert Finance.Returns.twr([0.02, 0.02], periods_per_year: 4) == {:ok, 0.082432}
      assert Finance.Returns.twr([]) == {:error, :insufficient_data}
      assert Finance.Returns.twr([0.1, "x"]) == {:error, :undefined}
      assert Finance.Returns.twr!([0.10, -0.05, 0.08]) == 0.1286
      assert_raise ArgumentError, fn -> Finance.Returns.twr!([]) end
    end

    test "an unknown option raises" do
      assert_raise NimbleOptions.ValidationError, fn ->
        Finance.Returns.cagr(1000, 2000, 10, precison: 2)
      end
    end
  end

  describe "volatility" do
    test "annualises the standard deviation of simple returns" do
      assert Finance.Returns.volatility([100, 102, 101, 103, 105]) == {:ok, 0.234528}
    end

    test "supports log returns and a custom period count" do
      assert Finance.Returns.volatility([100, 102, 101, 103, 105], returns: :log) ==
               {:ok, 0.233384}

      assert {:ok, monthly} =
               Finance.Returns.volatility([100, 102, 101, 103, 105], periods_per_year: 12)

      assert_in_delta monthly, 0.051178, 1.0e-6
    end

    test "needs at least three prices" do
      assert Finance.Returns.volatility([100, 105]) == {:error, :insufficient_data}
      assert Finance.Returns.volatility([100]) == {:error, :insufficient_data}
      assert Finance.Returns.volatility([]) == {:error, :insufficient_data}
    end

    test "rejects non-positive prices" do
      assert Finance.Returns.volatility([100, 0, 105]) == {:error, :undefined}
      assert Finance.Returns.volatility([100, -5, 105]) == {:error, :undefined}
    end

    test "rejects unknown options" do
      assert_raise NimbleOptions.ValidationError, fn ->
        Finance.Returns.volatility([100, 102, 105], returns: :geometric)
      end
    end

    test "volatility!/1 returns the bare value and raises on error" do
      assert Finance.Returns.volatility!([100, 102, 101, 103, 105]) == 0.234528
      assert_raise ArgumentError, fn -> Finance.Returns.volatility!([100]) end
    end
  end

  describe "ipmt/6 and ppmt/6" do
    test "match Excel for a simple loan" do
      assert {:ok, i} = Finance.TVM.ipmt(0.10 / 12, 1, 12, 1000)
      assert Float.round(i, 6) == -8.333333
      assert {:ok, p} = Finance.TVM.ppmt(0.10 / 12, 1, 12, 1000)
      assert Float.round(p, 6) == -79.582554
      assert {:ok, i6} = Finance.TVM.ipmt(0.10 / 12, 6, 12, 1000)
      assert Float.round(i6, 6) == -4.961665
    end

    test "interest plus principal equals the payment every period" do
      assert {:ok, payment} = Finance.TVM.pmt(0.10 / 12, 12, 1000)

      for per <- 1..12 do
        assert {:ok, i} = Finance.TVM.ipmt(0.10 / 12, per, 12, 1000)
        assert {:ok, p} = Finance.TVM.ppmt(0.10 / 12, per, 12, 1000)
        assert_in_delta i + p, payment, 1.0e-9
      end
    end

    test "at zero rate all of the payment is principal" do
      assert Finance.TVM.ipmt(0.0, 3, 12, 1200) == {:ok, 0.0}
      assert {:ok, p} = Finance.TVM.ppmt(0.0, 3, 12, 1200)
      assert_in_delta p, -100.0, 1.0e-9
    end

    test "supports annuity-due (type: 1) with no first-period interest" do
      assert Finance.TVM.ipmt(0.10 / 12, 1, 12, 1000, 0.0, 1) == {:ok, 0.0}
      # A later period discounts the interest one step; still reconciles to pmt.
      assert {:ok, payment} = Finance.TVM.pmt(0.10 / 12, 12, 1000, 0.0, 1)
      assert {:ok, i2} = Finance.TVM.ipmt(0.10 / 12, 2, 12, 1000, 0.0, 1)
      assert {:ok, p2} = Finance.TVM.ppmt(0.10 / 12, 2, 12, 1000, 0.0, 1)
      assert_in_delta i2 + p2, payment, 1.0e-9
    end

    test "rejects a period outside 1..nper or a non-integer period" do
      assert Finance.TVM.ipmt(0.10 / 12, 13, 12, 1000) == {:error, :undefined}
      assert Finance.TVM.ipmt(0.10 / 12, 0, 12, 1000) == {:error, :undefined}
      assert Finance.TVM.ipmt(0.10 / 12, 1.5, 12, 1000) == {:error, :undefined}
      assert Finance.TVM.ppmt(0.05, 1, 0, 1000) == {:error, :undefined}
    end

    test "bang variants return the bare value and raise on error" do
      assert Finance.TVM.ipmt!(0.0, 3, 12, 1200) == 0.0
      assert_raise ArgumentError, fn -> Finance.TVM.ppmt!(0.10 / 12, 13, 12, 1000) end
    end
  end

  describe "Finance.Bonds" do
    test "price and ytm are inverses" do
      assert {:ok, price} = Finance.Bonds.price(1000, 0.08, 0.10, 10)
      assert Finance.Bonds.ytm(1000, 0.08, price, 10) == {:ok, 0.1}
    end

    test "a par bond yields its coupon rate" do
      assert Finance.Bonds.price(100, 0.05, 0.05, 10) == {:ok, 100.0}
      assert Finance.Bonds.ytm(100, 0.05, 100.0, 10) == {:ok, 0.05}
    end

    test "degenerate maturity is undefined across the module" do
      assert Finance.Bonds.price(100, 0.05, 0.05, 0) == {:error, :undefined}
      assert Finance.Bonds.ytm(100, 0.05, 100.0, -1) == {:error, :undefined}
      assert Finance.Bonds.duration(0.05, 0.05, 0) == {:error, :undefined}
      assert Finance.Bonds.modified_duration(0.05, 0.05, 0) == {:error, :undefined}
      assert Finance.Bonds.convexity(0.05, 0.05, 0) == {:error, :undefined}
      # a fractional number of coupon periods is also undefined
      assert Finance.Bonds.price(100, 0.05, 0.05, 2.5, 1) == {:error, :undefined}
      assert Finance.Bonds.price(100, 0.05, 0.05, 10, 0) == {:error, :undefined}
    end

    test "ytm does not converge when no yield brackets the price" do
      assert Finance.Bonds.ytm(100, 0.05, -50.0, 10) == {:error, :did_not_converge}
    end

    test "ytm converges for long-maturity, low-yield bonds (solver overflow fallback)" do
      # Newton overshoots into an overflow on these long-dated flows; the solver
      # must fall through to bisection rather than give up. Regression for a
      # deep-discount 28-year semiannual bond and a 30-year monthly bond.
      {:ok, price} = Finance.Bonds.price(1000, 0.0097, 0.0233, 28)
      assert {:ok, recovered} = Finance.Bonds.ytm(1000, 0.0097, price, 28)
      assert_in_delta recovered, 0.0233, 1.0e-4

      {:ok, monthly} = Finance.Bonds.price(1000, 0.01, 0.02, 30, 12)
      assert {:ok, monthly_yield} = Finance.Bonds.ytm(1000, 0.01, monthly, 30, 12)
      assert_in_delta monthly_yield, 0.02, 1.0e-3
    end

    test "bang variants return bare values and raise on error" do
      assert Finance.Bonds.price!(100, 0.05, 0.05, 10) == 100.0
      assert Finance.Bonds.ytm!(100, 0.05, 100.0, 10) == 0.05
      assert Finance.Bonds.duration!(0.0, 0.05, 10, 1) == 10.0
      assert Finance.Bonds.modified_duration!(0.0, 0.05, 10, 1) == 9.52381
      assert Finance.Bonds.convexity!(0.0, 0.05, 10, 1) == 99.773243
      assert_raise ArgumentError, fn -> Finance.Bonds.price!(100, 0.05, 0.05, 0) end
    end
  end

  property "ytm recovers the yield a bond was priced at" do
    check all(
            coupon_bp <- integer(0..1500),
            yield_bp <- integer(100..1500),
            years <- integer(1..30)
          ) do
      coupon = coupon_bp / 10_000
      yield = yield_bp / 10_000
      assert {:ok, price} = Finance.Bonds.price(1000, coupon, yield, years)
      assert {:ok, recovered} = Finance.Bonds.ytm(1000, coupon, price, years)
      assert_in_delta recovered, yield, 1.0e-3
    end
  end

  describe "Finance.Rates" do
    test "effective and nominal are inverses (Excel EFFECT/NOMINAL)" do
      assert {:ok, ear} = Finance.Rates.effective_annual_rate(0.10, 12)
      assert Float.round(ear, 6) == 0.104713
      assert {:ok, nominal} = Finance.Rates.nominal_rate(ear, 12)
      assert_in_delta nominal, 0.10, 1.0e-9
    end

    test "round-trips through any compounding frequency" do
      assert {:ok, ear} = Finance.Rates.effective_annual_rate(0.08, 4)
      assert {:ok, nominal} = Finance.Rates.nominal_rate(ear, 4)
      assert_in_delta nominal, 0.08, 1.0e-9
    end

    test "continuous-to-periodic" do
      assert {:ok, r} = Finance.Rates.continuous_to_periodic(0.10, 1)
      assert Float.round(r, 6) == 0.105171
    end

    test "undefined for non-positive frequency or effective <= -1" do
      assert Finance.Rates.effective_annual_rate(0.10, 0) == {:error, :undefined}
      assert Finance.Rates.nominal_rate(0.10, 0) == {:error, :undefined}
      assert Finance.Rates.nominal_rate(-1.5, 12) == {:error, :undefined}
      assert Finance.Rates.continuous_to_periodic(0.1, 0) == {:error, :undefined}
    end

    test "bang variants" do
      assert {:ok, r} = Finance.Rates.continuous_to_periodic(0.10, 1)
      assert Finance.Rates.continuous_to_periodic!(0.10, 1) == r
      assert {:ok, ear} = Finance.Rates.effective_annual_rate(0.10, 12)
      assert Finance.Rates.nominal_rate!(ear, 12) == elem(Finance.Rates.nominal_rate(ear, 12), 1)
      assert_raise ArgumentError, fn -> Finance.Rates.effective_annual_rate!(0.10, 0) end
    end
  end

  describe "amortization_schedule/3,4" do
    test "produces a full schedule that pays the loan off exactly" do
      assert {:ok, rows} = Finance.TVM.amortization_schedule(0.10 / 12, 12, 1000)
      assert length(rows) == 12
      assert List.first(rows).period == 1
      assert List.last(rows).balance == 0.0
      assert_in_delta Enum.sum(Enum.map(rows, & &1.principal)), -1000.0, 1.0e-9
    end

    test "every row's interest and principal reconcile to its payment" do
      assert {:ok, rows} = Finance.TVM.amortization_schedule(0.10 / 12, 12, 1000)

      assert Enum.all?(rows, fn r ->
               Float.round(r.interest + r.principal - r.payment, 2) == 0.0
             end)

      assert List.first(rows).interest == -8.33
    end

    test ":precision controls the rounding of each column" do
      assert {:ok, rows} = Finance.TVM.amortization_schedule(0.10 / 12, 12, 1000, precision: 4)
      assert List.first(rows).interest == -8.3333
    end

    test "an ill-conditioned rate never drives the balance negative" do
      # 26.55%/period over 79 periods: `(1 + rate)^nper` is enormous, so the
      # cent-rounded level payment overshoots. The balance must still march down
      # to zero and stop there, never into money that isn't owed.
      assert {:ok, rows} = Finance.TVM.amortization_schedule(0.2655, 79, 409_239)
      balances = Enum.map(rows, & &1.balance)
      assert Enum.all?(balances, &(&1 >= 0.0))
      assert balances == Enum.sort(balances, :desc)
      assert List.last(rows).balance == 0.0
      assert_in_delta Enum.sum(Enum.map(rows, & &1.principal)), -409_239, 0.01
    end

    test "at zero rate principal is spread evenly" do
      assert {:ok, rows} = Finance.TVM.amortization_schedule(0.0, 4, 1000)
      assert Enum.map(rows, & &1.principal) == [-250.0, -250.0, -250.0, -250.0]
      assert List.last(rows).balance == 0.0
    end

    test "rejects a non-positive or non-integer term" do
      assert Finance.TVM.amortization_schedule(0.05, 0, 1000) == {:error, :undefined}
      assert Finance.TVM.amortization_schedule(0.05, 2.5, 1000) == {:error, :undefined}
    end

    test "bang variant returns the rows and raises on error" do
      assert [%{period: 1} | _] = Finance.TVM.amortization_schedule!(0.10 / 12, 12, 1000)
      assert_raise ArgumentError, fn -> Finance.TVM.amortization_schedule!(0.05, 0, 1000) end
    end

    test "computes in Decimal when given Decimal inputs" do
      assert {:ok, rows} =
               Finance.TVM.amortization_schedule(Decimal.new("0.05"), 3, Decimal.new("1000"))

      assert length(rows) == 3
      assert %Decimal{} = List.first(rows).payment
      assert Decimal.equal?(List.last(rows).balance, 0)

      total = Enum.reduce(rows, Decimal.new(0), fn r, acc -> Decimal.add(acc, r.principal) end)
      assert Decimal.equal?(total, Decimal.new("-1000.00"))
    end

    test "the Decimal path accepts integer and float principals" do
      assert {:ok, a} = Finance.TVM.amortization_schedule(Decimal.new("0.05"), 3, 1000)
      assert {:ok, b} = Finance.TVM.amortization_schedule(Decimal.new("0.05"), 3, 1000.0)
      assert Decimal.equal?(List.last(a).balance, 0)
      assert Decimal.equal?(List.last(b).balance, 0)
    end

    test "the Decimal path handles a zero rate" do
      assert {:ok, rows} =
               Finance.TVM.amortization_schedule(Decimal.new("0"), 4, Decimal.new("1000"))

      assert Enum.all?(rows, fn r -> Decimal.equal?(r.principal, Decimal.new("-250.00")) end)
      assert Decimal.equal?(List.last(rows).balance, 0)
    end
  end

  property "the principal portions repay the whole balance" do
    check all(
            rate_bp <- integer(1..2000),
            nper <- integer(2..60),
            pv <- integer(1_000..1_000_000)
          ) do
      rate = rate_bp / 10_000

      total =
        for(per <- 1..nper, do: elem(Finance.TVM.ppmt(rate, per, nper, pv), 1))
        |> Enum.sum()

      assert_in_delta total, -pv, 1.0e-4 * pv
    end
  end

  describe "properties" do
    # Build a two-flow investment with a known rate and confirm we recover it:
    # investing -P today and receiving P·(1+r)^years after `years` implies XIRR = r.
    property "recovers the rate of a synthetic single-period investment" do
      check all(
              principal <- integer(1_000..1_000_000),
              rate_bp <- integer(-5_000..50_000),
              years <- integer(1..10)
            ) do
        rate = rate_bp / 10_000
        start = ~D[2000-01-01]
        finish = Date.add(start, 365 * years)
        payout = principal * :math.pow(1 + rate, years)

        assert {:ok, found} = Finance.CashFlow.xirr([{start, -principal}, {finish, payout}])
        assert_in_delta found, rate, 1.0e-3
      end
    end

    property "xnpv at the xirr rate is ~zero" do
      check all(
              outflow <- integer(-1_000_000..-1),
              inflow <- integer(1..1_000_000),
              days <- integer(1..3650)
            ) do
        flows = [{~D[2000-01-01], outflow}, {Date.add(~D[2000-01-01], days), inflow}]

        case Finance.CashFlow.xirr(flows, precision: 10) do
          # Near a total-loss rate (1 + r ≈ 0) discounting is numerically
          # singular: tiny rounding in `r` blows up the discount factor. Skip
          # those degenerate cases — they say nothing about the identity.
          {:ok, rate} when 1 + rate > 0.01 ->
            assert {:ok, value} = Finance.CashFlow.xnpv(rate, flows, precision: 10)
            assert_in_delta value, 0.0, 1.0e-2 * (abs(inflow) + 1)

          _ ->
            :ok
        end
      end
    end

    property "the NPV at the returned rate is ~zero" do
      check all(
              outflow <- integer(-1_000_000..-1),
              inflow <- integer(1..1_000_000),
              days <- integer(1..3650)
            ) do
        flows = [{~D[2000-01-01], outflow}, {Date.add(~D[2000-01-01], days), inflow}]

        # A high-precision rate keeps rounding error negligible even where the
        # discount factor is steep; the guard still skips the 1 + r ≈ 0
        # singularity, where any rounding makes the factor explode.
        case Finance.CashFlow.xirr(flows, precision: 10) do
          {:ok, rate} when 1 + rate > 0.01 ->
            t = days / 365.0
            npv = outflow + inflow / :math.pow(1 + rate, t)
            assert_in_delta npv, 0.0, 1.0e-2 * (abs(inflow) + 1)

          _ ->
            :ok
        end
      end
    end
  end

  describe "solver and TVM stress properties" do
    # Finance a stream of positive inflows so the outlay is exactly their present
    # value at a known rate. That gives a single sign change (one real IRR) over
    # rates and horizons extreme enough to stress the Newton/bisection solver, and
    # we confirm the rate it returns drives the NPV back to ~zero.
    property "irr finds a root that zeroes the NPV across extreme rates and long horizons" do
      check all(
              rate_bp <- integer(-9_000..80_000),
              inflows <- list_of(integer(1..1_000_000), min_length: 1, max_length: 40)
            ) do
        rate = rate_bp / 10_000
        outlay = present_value_at(rate, Enum.with_index(inflows, 1))
        flows = [-outlay | inflows]

        case Finance.CashFlow.irr(flows, precision: 12) do
          {:ok, found} ->
            npv = present_value_at(found, Enum.with_index(flows, 0))
            assert_in_delta npv, 0.0, 1.0e-4 * (abs(outlay) + 1)

          {:error, reason} ->
            assert reason in [:did_not_converge, :single_signed_flow, :insufficient_data]
        end
      end
    end

    # The wild-edge-case contract: whatever signs the flows take — including the
    # many-sign-change cases that admit several IRRs — the solver must never
    # crash. It either returns a rate sitting on a genuine sign change of the NPV
    # (a real root) or one of the documented errors.
    property "irr never crashes on arbitrary flows; any rate it returns brackets a real root" do
      check all(amounts <- list_of(integer(-1_000_000..1_000_000), max_length: 30)) do
        case Finance.CashFlow.irr(amounts, precision: 10) do
          {:ok, rate} ->
            assert is_float(rate) and rate > -1.0
            indexed = Enum.with_index(amounts, 0)
            # Assert a zero-crossing rather than the NPV magnitude: a steep NPV is
            # large even a hair from its root, whereas a spurious non-root shows
            # no crossing at all. The window sits well inside the (-1, ∞) domain.
            h = min(max(abs(rate), 1.0) * 1.0e-6, (1.0 + rate) / 2)
            below = present_value_at(rate - h, indexed)
            above = present_value_at(rate + h, indexed)
            assert (below <= 0 and above >= 0) or (below >= 0 and above <= 0)

          {:error, reason} ->
            assert reason in [:insufficient_data, :single_signed_flow, :did_not_converge]
        end
      end
    end

    # Round-trip through the TVM solver: build a loan's present value from a known
    # rate, then confirm `rate/6` recovers it — over terms up to 600 periods.
    property "TVM.rate recovers the rate a loan was built at" do
      check all(
              rate_bp <- integer(1..5_000),
              nper <- integer(2..600),
              pmt <- integer(-1_000_000..-1)
            ) do
        rate = rate_bp / 10_000
        assert {:ok, pv} = Finance.TVM.pv(rate, nper, pmt, 0.0, 0)
        assert {:ok, found} = Finance.TVM.rate(nper, pmt, pv, 0.0, 0, precision: 10)
        assert_in_delta found, rate, 1.0e-4
      end
    end

    # `pv` and `fv` are inverse views of the same annuity, so composing them
    # returns the value untouched.
    property "pv and fv invert each other" do
      check all(
              rate_bp <- integer(0..50_000),
              nper <- integer(1..240),
              pmt <- integer(-1_000_000..1_000_000),
              pv <- integer(-1_000_000..1_000_000)
            ) do
        rate = rate_bp / 10_000
        assert {:ok, fv} = Finance.TVM.fv(rate, nper, pmt, pv, 0)
        assert {:ok, back} = Finance.TVM.pv(rate, nper, pmt, fv, 0)
        assert_in_delta back, pv, 1.0e-3 * (abs(pv) + abs(pmt) + 1)
      end
    end

    # Whatever the rate, term, or size, the integer-minor-unit engine must retire
    # the balance to exactly zero and have the principal portions sum to the loan.
    property "the amortization schedule pays the balance down to exactly zero" do
      check all(
              rate_bp <- integer(0..3_000),
              nper <- integer(1..360),
              pv <- integer(100..1_000_000)
            ) do
        rate = rate_bp / 10_000
        assert {:ok, rows} = Finance.TVM.amortization_schedule(rate, nper, pv)
        assert length(rows) == nper
        assert List.last(rows).balance == 0.0
        assert_in_delta Enum.sum(Enum.map(rows, & &1.principal)), -pv, 1.0e-6 * pv + 0.01
        balances = Enum.map(rows, & &1.balance)
        # Monotonically non-increasing, and it never overshoots into a balance you
        # don't owe — even when a cent-rounded payment is amplified over the term.
        assert balances == Enum.sort(balances, :desc)
        assert Enum.all?(balances, &(&1 >= 0.0))
      end
    end
  end

  # Present value of `{amount, period}` pairs at `rate`: Σ amount / (1 + rate)^period.
  defp present_value_at(rate, indexed_flows) do
    Enum.reduce(indexed_flows, 0.0, fn {amount, t}, acc ->
      acc + amount / :math.pow(1 + rate, t)
    end)
  end

  # A stand-in for ex_money's `%Money{}` (see test/support/money.ex).
  defp money(currency, amount), do: %Money{currency: currency, amount: Decimal.new(amount)}
end
