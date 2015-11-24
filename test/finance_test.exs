defmodule FinanceTest do
  use ExUnit.Case, async: true
  doctest Finance

  test "the truth" do
    assert 1 + 1 == 2
  end

  def multiply(integer) do
    integer * 2
  end

  test "irr" do
    
    cf0 = %Finance.Cashflow{date: Timex.Date.from({2013, 6, 1}), value: -100.0}
    cf2 = %Finance.Cashflow{date: Timex.Date.from({2014, 6, 1}), value: 200.0}

    IO.puts inspect(Finance.irr([cf0, cf2], Timex.Date.from({2013, 1, 1})))


  end

  test "Finance.Solver.solve/5" do
    f = fn(x) -> 10 - x end
    IO.puts inspect(Finance.Solver.solve(f, -20, 20, 0.00001, 100))
  end

  test "xirr/2 xichen27" do
    d = [{2014,04,15},{2014,05,15},{2014,10,19}]
    v = [-10000.0,305.6,500.0]
    assert Finance.xirr(d,v) == {:ok, -0.996815}
  end

  test "xirr/2 very good investment" do
    d = [{2015, 11, 1}, {2015,10,1}, {2015,6,1}]
    v = [-800_000, -2_200_000, 1_000_000]
    assert Finance.xirr(d,v) == {:ok, 21.118359}
  end


  test "xirr/2 bad investment" do
    d = [{1985, 1, 1}, {1990, 1, 1}, {1995, 1, 1}]
    v = [1000, -600, -200]
    assert Finance.xirr(d,v) == {:ok, -0.034592}
  end

  test "xirr/2 marano" do
    d = [{2014,11,7},{2015,5,6}]
    v = [900,-13.5]
    assert Finance.xirr(d,v) == {:ok, -0.9998}
  end

  test "xirr/2 repeated cashflow" do
    v = [1000.0, 
      2000.0, 
      -2000.0,
      -4000.0]
    d = [{2011,12,07}, 
      {2011,12,07}, 
      {2013,05,21}, 
      {2013,05,21}]

    assert Finance.xirr(d,v) == {:ok, 0.610359}
  end


  test "xirr/2 ok investment" do
    v = [1000.0, -600.0, -6000.0]
    d = [{1985,1,1},{1990,1,1},{1995,1,1}]

    assert Finance.xirr(d,v) == {:ok, 0.225683}
  end

  test "xirr/2 long investment" do
    v = [105187.06, 816709.66, 479069.684, 937309.708, 88622.661, 100000.0, 80000.0, 403627.95, 508117.9, 789706.87, -88622.661,
    -789706.871,-688117.9, -403627.95, 403627.95, 789706.871, 88622.661, 688117.9, 45129.14, 26472.08, 51793.2, 126605.59,
    278532.29, 99284.1, 58238.57, 113945.03, 405137.88, -405137.88, 165738.23, -165738.23, 144413.24, 84710.65, -84710.65, -144413.24]

    d = [{2011,12,07},{2011,12,07},{2011,12,07},{2012,01,18},{2012,07,03},{2012,07,03},{2012,07,19},{2012,07,23},{2012,07,23},{2012,07,23},
    {2012,09,11},{2012,09,11},{2012,09,11},{2012,09,11},{2012,09,12},{2012,09,12},{2012,09,12},{2012,09,12},{2013,03,11},{2013,03,11},
    {2013,03,11},{2013,03,11},{2013,03,28},{2013,03,28},{2013,03,28},{2013,03,28},{2013,05,21},{2013,05,21},{2013,05,21},{2013,05,21},
    {2013,05,21},{2013,05,21},{2013,05,21},{2013,05,21}]

    assert Finance.xirr(d,v) == {:error, "Could not converge"}
  end

  test "xirr/2 inverted ok investment" do
    v = [-1000.0, 600.0, 6000.0]
    d = [{1985,1,1},{1990,1,1},{1995,1,1}]

    assert Finance.xirr(d,v) == {:ok, 0.225683}
  end

  test "xirr/2 wrong size" do
    d = [
      {2014,04,15},
      {2014,10,19}
    ]
    v = [
      -10000.0,
      305.6,
      500.0
    ]
    assert Finance.xirr(d,v) == {:error, "Date and Value collections must have the same size"}
  end

  test "xirr/2 wrong values" do
    d = [
      {2014,04,15},
      {2014,10,19}
    ]
    v = [
      305.6,
      500.0
    ]

    assert Finance.xirr(d,v) == {:error, "Values should have at least one positive or negative value."}
  end

end
