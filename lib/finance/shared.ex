defmodule Finance.Shared do
  @moduledoc false
  # Cross-cutting helpers used across the Finance domain modules: amount
  # coercion, result rounding, the bang-variant unwrap, and the shared solver
  # options schema. Not part of the public API. Public types live in `Finance`.

  @options_schema NimbleOptions.new!(
                    guess: [
                      type: :float,
                      default: 0.1,
                      doc: "initial rate for the Newton-Raphson solver"
                    ],
                    tolerance: [
                      type: :float,
                      default: 1.0e-9,
                      doc: "convergence threshold on the net present value"
                    ],
                    max_iterations: [
                      type: :pos_integer,
                      default: 100,
                      doc: "cap on solver iterations before giving up"
                    ],
                    precision: [
                      type: :non_neg_integer,
                      default: 6,
                      doc: "decimal places the result is rounded to"
                    ],
                    solver: [
                      type: :atom,
                      doc:
                        "module implementing the `Finance.Solver` behaviour (defaults to `Finance.Solver.Newton`)"
                    ]
                  )

  @options_docs NimbleOptions.docs(@options_schema)

  @doc "Markdown docs for the shared solver options, for injection into moduledocs."
  @spec options_docs() :: String.t()
  def options_docs, do: @options_docs

  @doc """
  Validates options against the shared schema, applying defaults. Raises
  `NimbleOptions.ValidationError` on an unknown key or bad value.
  """
  @spec options(keyword) :: keyword
  def options(opts), do: NimbleOptions.validate!(opts, @options_schema)

  @doc "The solver module to use: a `:solver` option, else the app env, else `Finance.Solver.Newton`."
  @spec resolve_solver(keyword) :: module
  def resolve_solver(opts) do
    Keyword.get(opts, :solver) ||
      Application.get_env(:finance, :solver, Finance.Solver.Newton)
  end

  @doc "Round a result to the `:precision` in `opts`; `+ 0.0` collapses a negative zero to `0.0`."
  @spec round_value(number, keyword) :: float
  def round_value(value, opts) do
    Float.round(value, Keyword.fetch!(opts, :precision)) + 0.0
  end

  @doc "Unwrap an `{:ok, value}`; raise `ArgumentError` on `{:error, reason}`. Backs the `!` variants."
  @spec unwrap!({:ok, value} | {:error, atom}) :: value when value: var
  def unwrap!({:ok, value}), do: value
  def unwrap!({:error, reason}), do: raise(ArgumentError, "could not compute: #{reason}")

  @doc """
  Coerce a cash-flow amount to a float. Accepts plain numbers, `%Decimal{}`
  values, and `ex_money`'s `%Money{}` (its `Decimal` amount is taken; the
  currency is validated separately by `check_currency/1`).
  """
  @spec to_amount(number | struct()) :: float
  def to_amount(amount) when is_number(amount), do: amount / 1
  def to_amount(amount) when is_struct(amount, Decimal), do: Decimal.to_float(amount)
  def to_amount(amount) when is_struct(amount, Money), do: Decimal.to_float(amount.amount)

  @doc """
  Reject a series that mixes currencies. Only `%Money{}` amounts carry a currency;
  plain numbers and `%Decimal{}` are currency-neutral and ignored. Returns `:ok`,
  or `{:error, :mixed_currencies}` once two distinct currencies appear.
  """
  @spec check_currency([term]) :: :ok | {:error, :mixed_currencies}
  def check_currency(amounts) do
    amounts
    |> Enum.filter(&is_struct(&1, Money))
    |> Enum.map(& &1.currency)
    |> Enum.uniq()
    |> case do
      [_first, _second | _rest] -> {:error, :mixed_currencies}
      _none_or_one -> :ok
    end
  end

  @doc "Net present value of normalized flows at `rate`: `Σ amount / (1 + rate)^t`."
  @spec present_value([{number, number}], number) :: float
  def present_value(flows, rate) do
    # Discount with a negative exponent — `amount * (1 + rate)^-t` — rather than
    # dividing by `(1 + rate)^t`. At a high rate over a long horizon the factor
    # underflows to 0 (a negligible term, correctly ~0); the divide form would
    # instead overflow the denominator, and Erlang's `:math.pow` raises on
    # overflow, which would abort the whole solve.
    Enum.reduce(flows, 0.0, fn {t, amount}, acc ->
      acc + amount * :math.pow(1 + rate, -t)
    end)
  end

  @doc false
  # Bracket a sign change for the solvers: `{:ok, low, high}` with the NPV changing
  # sign across `[low, high]`, or `:diverged` when none is found.
  def bracket(flows) do
    low = safe_low(flows)
    expand(flows, low, present_value(flows, low), 1.0)
  end

  # The bracket's floor. As `rate` nears -1, `(1 + rate)^t` underflows to zero for
  # large `t`, so raise the floor just enough that the longest-dated flow's
  # discount factor stays finite — `-0.999999` for short flows, higher for long.
  defp safe_low(flows) do
    max_t = Enum.reduce(flows, 1.0, fn {t, _amount}, acc -> max(t, acc) end)
    max(:math.pow(1.0e-290, 1 / max_t), 1.0e-6) - 1.0
  end

  # Expand the upper bound until the NPV changes sign against `f_low`.
  defp expand(_flows, _low, _f_low, high) when high > 1.0e7, do: :diverged

  defp expand(flows, low, f_low, high) do
    if straddles_zero?(f_low, present_value(flows, high)),
      do: {:ok, low, high},
      else: expand(flows, low, f_low, high * 2 + 1)
  end

  # Whether `a` and `b` sit on opposite sides of zero. Comparing signs rather than
  # the product `a * b` avoids overflow when the NPV is astronomically large near
  # the bracket's floor for long-dated flows.
  defp straddles_zero?(a, b), do: (a <= 0 and b >= 0) or (a >= 0 and b <= 0)

  @doc false
  # Solve a batch in parallel: chunk into ~4 chunks per scheduler (amortizing the
  # per-task spawn) and run each chunk on its own task, preserving order.
  def solve_batch(batch, solve_fun) do
    batch
    |> Stream.chunk_every(chunk_size(length(batch)))
    |> Task.async_stream(fn chunk -> Enum.map(chunk, solve_fun) end,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.flat_map(fn {:ok, results} -> results end)
  end

  defp chunk_size(n) do
    chunks = System.schedulers_online() * 4
    max(1, div(n + chunks - 1, chunks))
  end
end
