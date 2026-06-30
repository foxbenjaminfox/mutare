defmodule Mutare.Mutator.MacroHost.Target do
  @moduledoc """
  One logical fragment and its mutations returned by a macro host.

  Build targets with `new/4`; the struct is opaque so Mutare can extend its internal
  representation without making every field part of the callback contract.
  """

  @opaque t :: %__MODULE__{
            original: Macro.t(),
            mutants: [Mutare.Mutator.mutation()],
            splice: (Macro.t(), Macro.t() -> Macro.t()),
            wrap: (Macro.t() -> Macro.t()) | nil,
            range: Sourceror.Range.t() | nil
          }

  @enforce_keys [:original, :mutants, :splice]
  defstruct [:original, :mutants, :splice, :wrap, :range]

  @doc """
  Build a hosted mutation target.

  Options are `:wrap`, a one-argument branch wrapper, and `:range`, the source range reported for
  the site. Mutare defaults `:wrap` to identity and `:range` to the original fragment's range.
  """
  @spec new(
          Macro.t(),
          [Mutare.Mutator.mutation()],
          (Macro.t(), Macro.t() -> Macro.t()),
          keyword()
        ) ::
          t()
  def new(original, mutants, splice, opts \\ [])

  def new(original, mutants, splice, opts)
      when is_list(mutants) and is_function(splice, 2) and is_list(opts) do
    wrap = Keyword.get(opts, :wrap)

    if not is_nil(wrap) and not is_function(wrap, 1) do
      raise ArgumentError, "a host target :wrap must be a 1-arity function, got: #{inspect(wrap)}"
    end

    %__MODULE__{
      original: original,
      mutants: mutants,
      splice: splice,
      wrap: wrap,
      range: Keyword.get(opts, :range)
    }
  end

  def new(_original, mutants, splice, _opts) do
    raise ArgumentError,
          "a host target requires a list of mutants and a 2-arity splice, got: " <>
            "mutants=#{inspect(mutants)}, splice=#{inspect(splice)}"
  end
end
