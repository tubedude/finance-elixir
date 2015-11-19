defmodule Finance do
  alias Timex.Date
  @moduledoc """
  Library to calculate IRR through the Bisection method.
  """
  defp pmap(collection, function) do
    me = self
    collection
    |> Enum.map(fn (element) -> spawn_link fn -> (send me, { self, function.(element) }) end end)
    |> Enum.map(fn (pid) -> receive do { ^pid, result } -> result end end)
  end

  defp xirr_reduction({period, value, rate}) do
    value / :math.pow(1 + rate, period)
  end

  @type rate :: float

  @doc """
      iex> d = [{2015, 11, 1}, {2015,10,1}, {2015,6,1}]
      iex> v = [-800_000, -2_200_000, 1_000_000]
      iex> Finance.xirr(d,v) 
      {:ok, 21.118359}
  """
  @spec xirr(list, list) :: rate

  def xirr(dates, values) when length(dates) != length(values) do
    {:error, 
      "Date and Value collections must have the same size"}
  end

  def xirr(dates, values) do
    cond do
      !verify_flow(values) ->
        {:error, "Values should have at least one positive or negative value."}
      length(dates) - length(values) == 0 && verify_flow(values) ->
        dates = dates
        |> pmap(&Date.from/1)
        min_date = Enum.min(dates)
        {dates, values, dates_values} = compact_flow(Enum.zip(dates, values), Date.to_days(min_date)) 
        calculate :xirr, dates_values, [], guess_rate(dates, values), -1.0, +1.0, 0
      true -> {:error, "Uncaught error"}
    end
  end # def xirr

  defp compact_flow(dates_values, min_date) do
    flow = Enum.reduce(dates_values, %{}, &organize_value(&1, &2, min_date))
    {Map.keys(flow), Map.values(flow), Enum.filter(flow, &(elem(&1,1) != 0))}
  end

  defp organize_value(date_value, dict, min_date) do
    {date, value} = date_value
    Dict.update(dict, ((Date.to_days(date) - min_date) / 365.0) , value, &(value + &1) )
  end

  defp verify_flow(values) do
    Enum.any?(values, fn(x) -> x > 0 end) &&
      Enum.any?(values, fn(x) -> x < 0 end)
  end

  @spec guess_rate(list, list ) :: rate
  defp guess_rate(dates, values) do
    {min_value, max_value} = Enum.min_max(values)
    period = length(dates) - 1
    Float.round(:math.pow(1 + abs(max_value / min_value) , 1 / period) - 1 , 3)
  end

  defp reached_boundry(rate, upper),
  do: abs(Float.round(rate - upper, 2)) == 0.0

  defp first_value_sign(dates_values) do
    [head | _] = Dict.to_list(dates_values)
    {_, first_value} = head
    cond do
      first_value < 0 -> 1
      first_value > 0 -> -1
    end
  end

  defp reduce_date_values(dates_values, rate) do
    acc = Dict.to_list(dates_values)
    |> pmap(fn (x) ->
      {
        elem(x,0),
        elem(x,1),
        rate
        } end)
    |> pmap(&(xirr_reduction/1))
    |> Enum.sum
    |> Float.round(4)
    acc * first_value_sign(dates_values)
  end

  defp calculate(:xirr, _           , 0.0 , rate, _     , _     , _  ), do: {:ok, Float.round(rate,6) }
  defp calculate(:xirr, _           , _   , -1.0, _     , _     , _  ), do: {:error, "Could not converge"}
  # defp calculate(:xirr, _           , _   , _   , _     , _     , 300), do:  {:error, "I give up"}
  defp calculate(:xirr, dates_values, _   , rate, bottom, upper , tries )  do
    acc = reduce_date_values(dates_values, rate)
    # IO.inspect "#{acc}; #{rate}; #{bottom}; #{upper}"
    cond do
      acc < 0 ->
        upper = rate
        rate = (bottom + rate) / 2
      acc > 0 && reached_boundry(rate, upper) ->
        bottom = rate
        rate = (rate + upper) / 2
        upper = upper + 1
      acc > 0 && !reached_boundry(rate, upper) ->
        bottom = rate
        rate = (rate + upper) / 2
      acc == 0.0 -> rate
    end
    tries = tries + 1
    calculate :xirr, dates_values, acc, rate, bottom, upper, tries
  end
end # defmodule Finance
