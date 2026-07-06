defmodule Finance.Depreciation do
  @moduledoc """
  Writing an asset down from its `cost` to its `salvage` value over its `life`.

  `sln/3` spreads the loss evenly; `syd/4`, `ddb/5`, and `db/5` are accelerated
  methods that depreciate more early on and return the amount for a single
  `period` (counting from 1).
  """

  import Finance.Shared, only: [unwrap!: 1]

  @type error :: Finance.error()

  @doc """
  Computes straight-line depreciation: the equal amount an asset is written down
  by each period as it declines from its `cost` to its `salvage` value over
  `life` periods.

  This is the plainest of the depreciation methods — it spreads the loss in
  value evenly, so every period sees the same write-down.

      iex> Finance.Depreciation.sln(10_000, 1_000, 5)
      {:ok, 1800.0}
  """
  @spec sln(number, number, number) :: {:ok, float} | {:error, error}
  def sln(cost, salvage, life)
      when is_number(cost) and is_number(salvage) and is_number(life) do
    if life <= 0 do
      {:error, :undefined}
    else
      {:ok, (cost - salvage) / life}
    end
  end

  @doc "Same as `sln/3`, but returns the value directly and raises `ArgumentError` on error."
  @spec sln!(number, number, number) :: float
  def sln!(cost, salvage, life), do: cost |> sln(salvage, life) |> unwrap!()

  @doc """
  Computes sum-of-years'-digits depreciation for a single `period` (counting from
  1).

  This is an accelerated method: it charges more depreciation in the early
  periods and less later on, which suits assets that lose most of their value up
  front. It returns the write-down for the one `period` you ask about rather than
  the whole schedule.

      iex> Finance.Depreciation.syd(10_000, 1_000, 5, 1)
      {:ok, 3000.0}

      iex> Finance.Depreciation.syd(10_000, 1_000, 5, 5)
      {:ok, 600.0}
  """
  @spec syd(number, number, number, number) :: {:ok, float} | {:error, error}
  def syd(cost, salvage, life, period)
      when is_number(cost) and is_number(salvage) and is_number(life) and is_number(period) do
    n = trunc(period)

    if life <= 0 or period != n or n < 1 or n > life do
      {:error, :undefined}
    else
      {:ok, (cost - salvage) * (life - period + 1) * 2 / (life * (life + 1))}
    end
  end

  @doc "Same as `syd/4`, but returns the value directly and raises `ArgumentError` on error."
  @spec syd!(number, number, number, number) :: float
  def syd!(cost, salvage, life, period), do: cost |> syd(salvage, life, period) |> unwrap!()

  @doc """
  Computes double-declining-balance depreciation for a single `period`.

  This is another accelerated method: each period it takes a fixed fraction of
  the remaining book value, so the write-down shrinks as the asset ages. The
  `factor` sets how aggressive that fraction is, defaulting to `2` for the usual
  double-declining rate. The depreciation is capped so it never drives the book
  value below `salvage`.

      iex> Finance.Depreciation.ddb(10_000, 1_000, 5, 1)
      {:ok, 4000.0}

      iex> Finance.Depreciation.ddb(10_000, 1_000, 5, 2)
      {:ok, 2400.0}
  """
  @spec ddb(number, number, number, number, number) :: {:ok, float} | {:error, error}
  def ddb(cost, salvage, life, period, factor \\ 2)
      when is_number(cost) and is_number(salvage) and is_number(life) and is_number(period) and
             is_number(factor) do
    n = trunc(period)

    if ddb_valid?(life, factor, period, n) do
      {:ok, declining_balance(cost, salvage, factor / life, n)}
    else
      {:error, :undefined}
    end
  end

  defp ddb_valid?(life, factor, period, n) do
    life > 0 and factor > 0 and period == n and n >= 1 and n <= life
  end

  @doc "Same as `ddb/5`, but returns the value directly and raises `ArgumentError` on error."
  @spec ddb!(number, number, number, number, number) :: float
  def ddb!(cost, salvage, life, period, factor \\ 2) do
    cost |> ddb(salvage, life, period, factor) |> unwrap!()
  end

  @doc """
  Computes fixed-declining-balance depreciation for a single `period`.

  Like `ddb/5`, this applies a constant rate to the declining book value, but the
  rate is derived directly from `cost`, `salvage`, and `life` (and rounded to
  three decimal places, matching what spreadsheets do). Use `month` to say how
  many months the asset was in service during its first year; it defaults to a
  full `12`, and a shorter first year spills the remaining depreciation into an
  extra final period.

      iex> Finance.Depreciation.db(10_000, 1_000, 5, 1)
      {:ok, 3690.0}

      iex> Finance.Depreciation.db(10_000, 1_000, 5, 2)
      {:ok, 2328.39}
  """
  @spec db(number, number, number, number, number) :: {:ok, float} | {:error, error}
  def db(cost, salvage, life, period, month \\ 12)
      when is_number(cost) and is_number(salvage) and is_number(life) and is_number(period) and
             is_number(month) do
    n = trunc(period)

    if db_valid?(cost, salvage, life, month, period, n) do
      {:ok, fixed_declining(cost, salvage, life, n, month)}
    else
      {:error, :undefined}
    end
  end

  @doc "Same as `db/5`, but returns the value directly and raises `ArgumentError` on error."
  @spec db!(number, number, number, number, number) :: float
  def db!(cost, salvage, life, period, month \\ 12) do
    cost |> db(salvage, life, period, month) |> unwrap!()
  end

  defp db_valid?(cost, salvage, life, month, period, n) do
    cost > 0 and salvage >= 0 and life > 0 and month >= 1 and month <= 12 and
      period == n and n >= 1 and n <= life + 1
  end

  # Walk periods 1..period, carrying accumulated depreciation, and return the
  # amount for the final period. Depreciation stops at the salvage floor.
  defp declining_balance(cost, salvage, rate, period) do
    Enum.reduce(1..period, {0.0, 0.0}, fn _p, {accumulated, _dep} ->
      book = cost - accumulated
      dep = max(min(book * rate, book - salvage), 0.0)
      {accumulated + dep, dep}
    end)
    |> elem(1)
  end

  defp fixed_declining(cost, salvage, life, period, month) do
    rate = Float.round(1 - :math.pow(salvage / cost, 1 / life), 3)

    Enum.reduce(1..period, {0.0, 0.0}, fn p, {accumulated, _dep} ->
      dep = db_period(cost, accumulated, rate, life, month, p)
      {accumulated + dep, dep}
    end)
    |> elem(1)
  end

  defp db_period(cost, _accumulated, rate, _life, month, 1), do: cost * rate * month / 12

  defp db_period(cost, accumulated, rate, life, month, period) do
    if period <= life do
      (cost - accumulated) * rate
    else
      # The partial last period when the first year was shorter than 12 months.
      (cost - accumulated) * rate * (12 - month) / 12
    end
  end
end
