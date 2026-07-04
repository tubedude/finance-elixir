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

    property "the NPV at the returned rate is ~zero" do
      check all(
              outflow <- integer(-1_000_000..-1),
              inflow <- integer(1..1_000_000),
              days <- integer(1..3650)
            ) do
        flows = [{~D[2000-01-01], outflow}, {Date.add(~D[2000-01-01], days), inflow}]

        case Finance.xirr(flows) do
          {:ok, rate} ->
            t = days / 365.0
            npv = outflow + inflow / :math.pow(1 + rate, t)
            assert_in_delta npv, 0.0, 1.0e-2 * (abs(inflow) + 1)

          {:error, _} ->
            :ok
        end
      end
    end
  end
end
