defmodule FinanceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Finance

  describe "xirr/2 regression cases" do
    test "very good investment" do
      d = [{2015, 11, 1}, {2015, 10, 1}, {2015, 6, 1}]
      v = [-800_000, -2_200_000, 1_000_000]
      assert Finance.xirr(d, v) == {:ok, 21.118359}
    end

    test "bad investment" do
      d = [{1985, 1, 1}, {1990, 1, 1}, {1995, 1, 1}]
      v = [1000, -600, -200]
      assert Finance.xirr(d, v) == {:ok, -0.034592}
    end

    test "marano" do
      d = [{2014, 11, 7}, {2015, 5, 6}]
      v = [900, -13.5]
      assert Finance.xirr(d, v) == {:ok, -0.9998}
    end

    test "xichen27" do
      d = [{2014, 4, 15}, {2014, 5, 15}, {2014, 10, 19}]
      v = [-10_000.0, 305.6, 500.0]
      assert Finance.xirr(d, v) == {:ok, -0.996815}
    end

    test "repeated cashflow on the same date is combined" do
      v = [1000.0, 2000.0, -2000.0, -4000.0]
      d = [{2011, 12, 7}, {2011, 12, 7}, {2013, 5, 21}, {2013, 5, 21}]
      assert Finance.xirr(d, v) == {:ok, 0.610359}
    end

    test "ok investment" do
      v = [1000.0, -600.0, -6000.0]
      d = [{1985, 1, 1}, {1990, 1, 1}, {1995, 1, 1}]
      assert Finance.xirr(d, v) == {:ok, 0.225683}
    end

    test "sign of the whole series does not matter" do
      d = [{1985, 1, 1}, {1990, 1, 1}, {1995, 1, 1}]

      assert Finance.xirr(d, [1000.0, -600.0, -6000.0]) ==
               Finance.xirr(d, [-1000.0, 600.0, 6000.0])
    end
  end

  describe "input shapes" do
    test "accepts {date, amount} pairs" do
      assert Finance.xirr([{~D[2019-01-01], -1000}, {~D[2020-01-01], 1100}]) == {:ok, 0.1}
    end

    test "accepts Date structs and {y, m, d} tuples interchangeably" do
      pairs = Finance.xirr([{~D[2019-01-01], -1000}, {~D[2020-01-01], 1100}])
      tuples = Finance.xirr([{2019, 1, 1}, {2020, 1, 1}], [-1000, 1100])
      assert pairs == tuples
    end

    test "xirr!/2 returns the bare rate" do
      assert Finance.xirr!([{2019, 1, 1}, {2020, 1, 1}], [-1000, 1100]) == 0.1
    end

    test "xirr!/1 raises on error" do
      assert_raise ArgumentError, fn -> Finance.xirr!([{~D[2020-01-01], 100}]) end
    end
  end

  describe "options" do
    test ":precision controls rounding of the result" do
      flows = [{~D[2019-01-01], -1000}, {~D[2020-01-01], 1100}]
      assert Finance.xirr(flows, precision: 2) == {:ok, 0.1}
      assert {:ok, rate} = Finance.xirr(flows, precision: 10)
      assert_in_delta rate, 0.1, 1.0e-6
    end

    test ":guess still converges to the same rate" do
      flows = [
        {~D[2015-06-01], 1_000_000},
        {~D[2015-10-01], -2_200_000},
        {~D[2015-11-01], -800_000}
      ]

      assert Finance.xirr(flows, guess: 5.0) == Finance.xirr(flows)
    end

    test "options work with the two-list form via xirr/3" do
      assert Finance.xirr([{2019, 1, 1}, {2020, 1, 1}], [-1000, 1100], precision: 3) == {:ok, 0.1}
    end

    test "an unknown option key raises (caller error, not a data error)" do
      flows = [{~D[2019-01-01], -1000}, {~D[2020-01-01], 1100}]

      assert_raise NimbleOptions.ValidationError, fn ->
        Finance.xirr(flows, precison: 2)
      end
    end

    test "an out-of-type option value raises" do
      assert_raise NimbleOptions.ValidationError, fn ->
        Finance.irr([-1000, 1100], max_iterations: -5)
      end

      assert_raise NimbleOptions.ValidationError, fn ->
        Finance.npv(0.1, [-1000, 1100], precision: 1.5)
      end
    end
  end

  describe "errors" do
    test "mismatched list lengths" do
      assert Finance.xirr([{2014, 4, 15}, {2014, 10, 19}], [-10_000.0, 305.6, 500.0]) ==
               {:error, :mismatched_lengths}
    end

    test "all amounts the same sign" do
      assert Finance.xirr([{2014, 4, 15}, {2014, 10, 19}], [305.6, 500.0]) ==
               {:error, :single_signed_flow}
    end

    test "positive and negative flow on the same day cancel out" do
      d = [{2014, 4, 15}, {2014, 4, 15}, {2014, 10, 19}]
      v = [-10_000.0, 10_000.0, 500.0]
      assert Finance.xirr(d, v) == {:error, :single_signed_flow}
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

      assert Finance.xirr(d, v) == {:error, :did_not_converge}
    end

    test "empty input" do
      assert Finance.xirr([]) == {:error, :insufficient_data}
    end

    test "an invalid date is reported" do
      flows = [{{2019, 13, 1}, -100}, {{2019, 1, 1}, 100}]
      assert Finance.xirr(flows) == {:error, :invalid_date}
    end
  end

  describe "solver bisection fallback" do
    # `max_iterations: 1` starves Newton so it bails to the bisection fallback.
    test "returns a value when a root is bracketed" do
      assert {:ok, _rate} = Finance.irr([-1000, 500, 500, 300], max_iterations: 1)
    end

    test "diverges when no root can be bracketed" do
      # An all-positive series has no rate; bisection expands its bracket, then gives up.
      assert Finance.rate(10, 100, 1000, 0.0, 0, max_iterations: 1) ==
               {:error, :did_not_converge}
    end
  end

  describe "xnpv/2" do
    test "discounts a single future flow" do
      flows = [{~D[2019-01-01], -1000}, {~D[2020-01-01], 1000}]
      assert Finance.xnpv(0.1, flows) == {:ok, -90.909091}
    end

    test "does not require a sign change" do
      flows = [{~D[2019-01-01], 500}, {~D[2020-01-01], 500}]
      assert {:ok, value} = Finance.xnpv(0.1, flows)
      assert_in_delta value, 500 + 500 / 1.1, 1.0e-6
    end

    test ":precision controls rounding" do
      flows = [{~D[2019-01-01], -1000}, {~D[2020-01-01], 1000}]
      assert {:ok, value} = Finance.xnpv(0.1, flows, precision: 2)
      assert value == -90.91
    end

    test "combines flows on the same date" do
      flows = [{~D[2019-01-01], -1000}, {~D[2019-01-01], 400}, {~D[2020-01-01], 1000}]
      assert Finance.xnpv(0.1, flows) == {:ok, 309.090909}
    end

    test "propagates normalization errors" do
      assert Finance.xnpv(0.1, []) == {:error, :insufficient_data}
    end

    test "xnpv!/2 returns the bare value and raises on error" do
      assert Finance.xnpv!(0.1, [{~D[2019-01-01], -1000}, {~D[2020-01-01], 1100}]) == 0.0
      assert_raise ArgumentError, fn -> Finance.xnpv!(0.1, []) end
    end
  end

  describe "irr/1 (periodic)" do
    test "simple two-flow investment" do
      assert Finance.irr([-1000, 1100]) == {:ok, 0.1}
    end

    test "matches xirr on equally spaced annual dates" do
      # Non-leap consecutive years give exactly one-year periods.
      dates = [~D[2001-01-01], ~D[2002-01-01], ~D[2003-01-01], ~D[2004-01-01]]
      amounts = [-1000, 500, 500, 300]
      assert Finance.irr(amounts) == Finance.xirr(dates, amounts)
    end

    test "requires at least one positive and one negative amount" do
      assert Finance.irr([100, 200, 300]) == {:error, :single_signed_flow}
      assert Finance.irr([-500]) == {:error, :insufficient_data}
    end

    test "irr!/1 returns the bare rate and raises on error" do
      assert Finance.irr!([-1000, 1100]) == 0.1
      assert_raise ArgumentError, fn -> Finance.irr!([1, 2, 3]) end
    end
  end

  describe "npv/2 (periodic)" do
    test "first amount sits at period 0 (undiscounted)" do
      # -1000 + 600/1.1 + 600/1.1^2
      assert Finance.npv(0.1, [-1000, 600, 600]) == {:ok, 41.322314}
    end

    test "npv at the irr rate is ~zero" do
      amounts = [-1000, 500, 500, 300]
      assert {:ok, rate} = Finance.irr(amounts)
      assert {:ok, value} = Finance.npv(rate, amounts)
      assert_in_delta value, 0.0, 1.0e-3
    end

    test "empty series is an error" do
      assert Finance.npv(0.1, []) == {:error, :insufficient_data}
    end

    test "npv!/2 returns the bare value" do
      assert Finance.npv!(0.1, [-1000, 1100]) == 0.0
    end
  end

  describe "mirr/3" do
    test "Microsoft's documented example" do
      values = [-120_000, 39_000, 30_000, 21_000, 37_000, 46_000]
      assert Finance.mirr(values, 0.10, 0.12) == {:ok, 0.126094}
    end

    test "requires both an inflow and an outflow" do
      assert Finance.mirr([100, 200], 0.1, 0.1) == {:error, :single_signed_flow}
      assert Finance.mirr([-100], 0.1, 0.1) == {:error, :insufficient_data}
    end

    test "mirr!/3 returns the bare rate" do
      values = [-120_000, 39_000, 30_000, 21_000, 37_000, 46_000]
      assert Finance.mirr!(values, 0.10, 0.12) == 0.126094
    end
  end

  describe "Decimal amounts (optional dependency)" do
    test "xirr accepts Decimal amounts, matching float results" do
      decimals = [{~D[2019-01-01], Decimal.new("-1000")}, {~D[2020-01-01], Decimal.new("1100")}]
      floats = [{~D[2019-01-01], -1000.0}, {~D[2020-01-01], 1100.0}]
      assert Finance.xirr(decimals) == Finance.xirr(floats)
      assert Finance.xirr(decimals) == {:ok, 0.1}
    end

    test "periodic functions accept Decimal amounts" do
      assert Finance.irr([Decimal.new("-1000"), Decimal.new("1100")]) == {:ok, 0.1}

      assert Finance.mirr([Decimal.new("-100"), Decimal.new("50"), Decimal.new("80")], 0.1, 0.1) ==
               Finance.mirr([-100, 50, 80], 0.1, 0.1)
    end
  end

  describe "TVM scalars" do
    test "fv, pv, pmt, nper are mutually consistent" do
      # A payment that pays off pv over nper periods should give fv ~ 0.
      assert {:ok, payment} = Finance.pmt(0.10, 10, 1000)
      assert_in_delta payment, -162.745395, 1.0e-6
      assert {:ok, future} = Finance.fv(0.10, 10, payment, 1000)
      assert_in_delta future, 0.0, 1.0e-4
    end

    test "pv inverts fv" do
      assert {:ok, future} = Finance.fv(0.08, 5, 0, -1000)
      assert {:ok, present} = Finance.pv(0.08, 5, 0, future)
      assert_in_delta present, -1000.0, 1.0e-6
    end

    test "nper inverts pmt" do
      assert {:ok, payment} = Finance.pmt(0.05, 12, 1000)
      assert {:ok, periods} = Finance.nper(0.05, payment, 1000)
      assert_in_delta periods, 12.0, 1.0e-6
    end

    test "rate inverts pmt (reuses the irr solver)" do
      assert {:ok, payment} = Finance.pmt(0.03, 24, 5000)
      assert Finance.rate(24, payment, 5000) == {:ok, 0.03}
    end

    test "zero-rate branches" do
      assert Finance.fv(0.0, 10, -100, 0) == {:ok, 1000.0}
      assert Finance.pv(0.0, 10, -100, 0) == {:ok, 1000.0}
      assert Finance.pmt(0.0, 10, 1000) == {:ok, -100.0}
      assert Finance.nper(0.0, -100, 1000) == {:ok, 10.0}
    end

    test "type: 1 (annuity due) differs from ordinary" do
      assert {:ok, ordinary} = Finance.fv(0.05, 10, -100, 0, 0)
      assert {:ok, due} = Finance.fv(0.05, 10, -100, 0, 1)
      # Paying at the start of each period earns one extra period of interest.
      assert_in_delta due, ordinary * 1.05, 1.0e-6
    end

    test "undefined and non-convergent cases" do
      assert Finance.pmt(0.05, 0, 1000) == {:error, :undefined}
      assert Finance.nper(0.0, 0, 1000) == {:error, :undefined}
      assert Finance.rate(10.5, -100, 1000) == {:error, :undefined}
    end

    test "bang variants return bare values and raise" do
      assert Finance.fv!(0.0, 10, -100, 0) == 1000.0
      assert Finance.pv!(0.0, 10, -100, 0) == 1000.0
      assert Finance.pmt!(0.0, 10, 1000) == -100.0
      assert Finance.nper!(0.0, -100, 1000) == 10.0
      assert Finance.rate!(10, -100, 1000) == 0.0
      assert_raise ArgumentError, fn -> Finance.pmt!(0.05, 0, 1000) end
      assert_raise ArgumentError, fn -> Finance.rate!(10, 100, 1000) end
    end

    test "rate with a single-signed series cannot converge" do
      assert Finance.rate(10, 100, 1000) == {:error, :did_not_converge}
    end

    test "nper is undefined when 1 + rate <= 0" do
      assert Finance.nper(-1.5, -100, 1000) == {:error, :undefined}
    end

    test "nper is undefined when the payment exactly services the balance" do
      # pmt/rate cancels pv, so the log argument's denominator is zero.
      assert Finance.nper(0.05, -50, 1000) == {:error, :undefined}
    end

    test "rate handles annuity-due (type: 1)" do
      assert {:ok, _rate} = Finance.rate(10, -100, 1000, 0.0, 1)
    end

    test "invalid options still raise through rate/6" do
      assert_raise NimbleOptions.ValidationError, fn ->
        Finance.rate(10, -100, 1000, 0.0, 0, precision: -1)
      end
    end
  end

  describe "depreciation" do
    test "straight-line spreads the loss evenly" do
      assert Finance.sln(10_000, 1_000, 5) == {:ok, 1800.0}
      assert Finance.sln(10_000, 1_000, 0) == {:error, :undefined}
      assert Finance.sln!(10_000, 1_000, 5) == 1800.0
    end

    test "sum-of-years'-digits accelerates then tapers" do
      assert Finance.syd(10_000, 1_000, 5, 1) == {:ok, 3000.0}
      assert Finance.syd(10_000, 1_000, 5, 5) == {:ok, 600.0}
      # The four remaining years plus the first sum to the depreciable base.
      total = for(p <- 1..5, do: elem(Finance.syd(10_000, 1_000, 5, p), 1)) |> Enum.sum()
      assert_in_delta total, 9000.0, 1.0e-9
    end

    test "syd rejects out-of-range and non-positive life" do
      assert Finance.syd(10_000, 1_000, 5, 6) == {:error, :undefined}
      assert Finance.syd(10_000, 1_000, 5, 0) == {:error, :undefined}
      assert Finance.syd(10_000, 1_000, 0, 1) == {:error, :undefined}
      assert_raise ArgumentError, fn -> Finance.syd!(10_000, 1_000, 5, 6) end
    end

    test "double-declining balance never drops below salvage and sums to the base" do
      assert Finance.ddb(10_000, 1_000, 5, 1) == {:ok, 4000.0}
      assert Finance.ddb(10_000, 1_000, 5, 5) == {:ok, 296.0}
      total = for(p <- 1..5, do: elem(Finance.ddb(10_000, 1_000, 5, p), 1)) |> Enum.sum()
      assert_in_delta total, 9000.0, 1.0e-9
    end

    test "ddb honours a custom factor and rejects invalid input" do
      assert {:ok, value} = Finance.ddb(10_000, 1_000, 5, 1, 3)
      assert value == 6000.0
      assert Finance.ddb(10_000, 1_000, 0, 1) == {:error, :undefined}
      assert Finance.ddb(10_000, 1_000, 5, 2.5) == {:error, :undefined}
      assert Finance.ddb(10_000, 1_000, 5, 6) == {:error, :undefined}
      assert Finance.ddb!(10_000, 1_000, 5, 1) == 4000.0
    end

    test "fixed-declining balance with a full first year" do
      assert Finance.db(10_000, 1_000, 5, 1) == {:ok, 3690.0}
      assert Finance.db(10_000, 1_000, 5, 2) == {:ok, 2328.39}
      assert Finance.db!(10_000, 1_000, 5, 1) == 3690.0
    end

    test "db with a short first year has a partial final period" do
      assert {:ok, first} = Finance.db(10_000, 1_000, 5, 1, 6)
      # First-year depreciation is prorated to 6 months.
      assert_in_delta first, 10_000 * 0.369 * 6 / 12, 1.0e-9
      assert {:ok, last} = Finance.db(10_000, 1_000, 5, 6, 6)
      assert last > 0
    end

    test "db rejects invalid input" do
      assert Finance.db(0, 1_000, 5, 1) == {:error, :undefined}
      assert Finance.db(10_000, 1_000, 5, 1, 13) == {:error, :undefined}
      assert Finance.db(10_000, 1_000, 5, 2.5) == {:error, :undefined}
    end
  end

  describe "volatility" do
    test "annualises the standard deviation of simple returns" do
      assert Finance.volatility([100, 102, 101, 103, 105]) == {:ok, 0.234528}
    end

    test "supports log returns and a custom period count" do
      assert Finance.volatility([100, 102, 101, 103, 105], returns: :log) == {:ok, 0.233384}
      assert {:ok, monthly} = Finance.volatility([100, 102, 101, 103, 105], periods_per_year: 12)
      assert_in_delta monthly, 0.051178, 1.0e-6
    end

    test "needs at least three prices" do
      assert Finance.volatility([100, 105]) == {:error, :insufficient_data}
      assert Finance.volatility([100]) == {:error, :insufficient_data}
      assert Finance.volatility([]) == {:error, :insufficient_data}
    end

    test "rejects non-positive prices" do
      assert Finance.volatility([100, 0, 105]) == {:error, :undefined}
      assert Finance.volatility([100, -5, 105]) == {:error, :undefined}
    end

    test "rejects unknown options" do
      assert_raise NimbleOptions.ValidationError, fn ->
        Finance.volatility([100, 102, 105], returns: :geometric)
      end
    end

    test "volatility!/1 returns the bare value and raises on error" do
      assert Finance.volatility!([100, 102, 101, 103, 105]) == 0.234528
      assert_raise ArgumentError, fn -> Finance.volatility!([100]) end
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

        assert {:ok, found} = Finance.xirr([{start, -principal}, {finish, payout}])
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

        case Finance.xirr(flows, precision: 10) do
          # Near a total-loss rate (1 + r ≈ 0) discounting is numerically
          # singular: tiny rounding in `r` blows up the discount factor. Skip
          # those degenerate cases — they say nothing about the identity.
          {:ok, rate} when 1 + rate > 0.01 ->
            assert {:ok, value} = Finance.xnpv(rate, flows, precision: 10)
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
        case Finance.xirr(flows, precision: 10) do
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
end
