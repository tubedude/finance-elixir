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
  Coerce a cash-flow amount to a float. Accepts plain numbers and, when the
  optional Decimal dependency is present, `%Decimal{}` values.
  """
  @spec to_amount(number | Decimal.t()) :: float
  def to_amount(%Decimal{} = amount), do: Decimal.to_float(amount)
  def to_amount(amount) when is_number(amount), do: amount / 1

  @doc "Net present value of normalized flows at `rate`: `Σ amount / (1 + rate)^t`."
  @spec present_value([{number, number}], number) :: float
  def present_value(flows, rate) do
    Enum.reduce(flows, 0.0, fn {t, amount}, acc ->
      acc + amount / :math.pow(1 + rate, t)
    end)
  end
end
