defmodule Finance.Rates do
  @moduledoc """
  Converting between the different ways an interest rate can be quoted.

  A nominal rate paired with a compounding frequency, the effective annual rate
  it actually earns, and a continuously-compounded rate all describe the same
  return in different terms. These functions move between them.
  """

  import Finance.Shared, only: [unwrap!: 1]

  @type error :: Finance.error()

  @doc """
  The effective annual rate earned by a `nominal` rate compounded `m` times a year.

      (1 + nominal / m)^m − 1

      iex> {:ok, ear} = Finance.Rates.effective_annual_rate(0.10, 12)
      iex> Float.round(ear, 6)
      0.104713
  """
  @spec effective_annual_rate(number, number) :: {:ok, float} | {:error, error}
  def effective_annual_rate(nominal, m) when is_number(nominal) and is_number(m) do
    cond do
      m <= 0 -> {:error, :undefined}
      # A negative base raised to a fractional `m` has no real value.
      1 + nominal / m < 0 -> {:error, :undefined}
      true -> {:ok, :math.pow(1 + nominal / m, m) - 1}
    end
  end

  @doc "Same as `effective_annual_rate/2`, but returns the rate directly and raises `ArgumentError` on error."
  @spec effective_annual_rate!(number, number) :: float
  def effective_annual_rate!(nominal, m), do: nominal |> effective_annual_rate(m) |> unwrap!()

  @doc """
  The nominal rate that, compounded `m` times a year, produces the `effective`
  annual rate. The inverse of `effective_annual_rate/2`.

      m · ((1 + effective)^(1/m) − 1)

      iex> {:ok, ear} = Finance.Rates.effective_annual_rate(0.10, 12)
      iex> {:ok, nominal} = Finance.Rates.nominal_rate(ear, 12)
      iex> Float.round(nominal, 10)
      0.1
  """
  @spec nominal_rate(number, number) :: {:ok, float} | {:error, error}
  def nominal_rate(effective, m) when is_number(effective) and is_number(m) do
    cond do
      m <= 0 -> {:error, :undefined}
      # `1 + effective == 0` is the total-loss case: `pow(0, 1/m)` is 0, so the
      # inverse of `effective_annual_rate` still holds there.
      1 + effective < 0 -> {:error, :undefined}
      true -> {:ok, m * (:math.pow(1 + effective, 1 / m) - 1)}
    end
  end

  @doc "Same as `nominal_rate/2`, but returns the rate directly and raises `ArgumentError` on error."
  @spec nominal_rate!(number, number) :: float
  def nominal_rate!(effective, m), do: effective |> nominal_rate(m) |> unwrap!()

  @doc """
  The per-period rate equivalent to a continuously-compounded annual `rate`, for
  `periods` periods a year.

      e^(rate / periods) − 1

      iex> {:ok, r} = Finance.Rates.continuous_to_periodic(0.10, 1)
      iex> Float.round(r, 6)
      0.105171
  """
  @spec continuous_to_periodic(number, number) :: {:ok, float} | {:error, error}
  def continuous_to_periodic(rate, periods) when is_number(rate) and is_number(periods) do
    if periods <= 0 do
      {:error, :undefined}
    else
      {:ok, :math.exp(rate / periods) - 1}
    end
  end

  @doc "Same as `continuous_to_periodic/2`, but returns the rate directly and raises `ArgumentError` on error."
  @spec continuous_to_periodic!(number, number) :: float
  def continuous_to_periodic!(rate, periods) do
    rate |> continuous_to_periodic(periods) |> unwrap!()
  end
end
