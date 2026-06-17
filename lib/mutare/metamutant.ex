defmodule Mutare.Metamutant do
  @moduledoc """
  The shape of a selector `case` subject in the metamutant.

  This is the one piece of generated structure that `Mutare.Transform` writes
  and that the readers (`Mutare.Manifest`, used by both `Mutare.Coverage` and
  `Mutare.Poison`) recognise. Owning it in a single module keeps the producer
  from hand-building the same AST literal twice and keeps the consumers from
  re-deriving how to spot a selector.

  A selector `case` looks like:

      case :persistent_term.get(:mutare_active, 0) do
        17 -> <mutated>     # one clause per mutant id hosted here
        18 -> <mutated>
        _  -> <original>    # the catch-all: baseline + every inactive mutant
      end

  The subject (`:persistent_term.get(...)`) is the same whether the `case` is an
  in-place selector or a lifted dispatcher — only the clause bodies differ — so
  recognising the subject is enough to find every selector.

    * `subject_ast/0` builds the subject `Transform` splices in,
    * `subject?/1` recognises it (the predicate `Mutare.Manifest` uses to walk a
      rendered metamutant).

  `subject?/1` is tolerant of how the subject is *parsed back*: `Code.string_to_quoted`
  leaves `:persistent_term`/`:mutare_active` as bare atoms, while `Sourceror.parse_string!`
  wraps every literal in a `{:__block__, _, [literal]}`. `Mutare.Manifest` re-parses with
  Sourceror (it needs `Sourceror.get_range/1` for the generated line ranges), so the
  predicate has to see through that wrapping.

  `Mutare.Selector` owns the runtime constants (the `:persistent_term` key and
  the baseline id); this module owns their AST.
  """

  @key Mutare.Selector.key()
  @baseline Mutare.Selector.baseline()

  @doc """
  The selector subject `Transform` splices into every selector/dispatcher `case`:
  `:persistent_term.get(<key>, <baseline>)`.
  """
  @spec subject_ast() :: Macro.t()
  def subject_ast do
    # Block-wrap the literal args (the clean-meta convention). Bare literals render
    # fine as a `case` *subject*, but as a match RHS — `mutare_active =
    # :persistent_term.get(:mutare_active, 0)` in a lifted dispatcher — the Elixir
    # formatter's `force_args?/2` inspects the call args and crashes on a bare atom
    # (it expects `{_, meta, _}` nodes). Wrapping makes every spliced subject render
    # cleanly in any position; `subject?/1` sees through the wrapping.
    {{:., [], [:persistent_term, :get]}, [],
     [{:__block__, [], [@key]}, {:__block__, [], [@baseline]}]}
  end

  @doc """
  Whether `node` is a selector subject — the predicate `Mutare.Manifest` walks with.

  Tolerant of the `{:__block__, _, [literal]}` wrapping `Sourceror.parse_string!`
  adds (and a no-op on the bare-atom shape `Code.string_to_quoted` produces).
  """
  @spec subject?(Macro.t()) :: boolean()
  def subject?({{:., _, [mod, :get]}, _, [key | _]}),
    do: unwrap(mod) == :persistent_term and unwrap(key) == @key

  def subject?(_), do: false

  # See through Sourceror's literal wrapping (`{:__block__, _, [:persistent_term]}`);
  # a bare atom passes through untouched.
  defp unwrap({:__block__, _meta, [literal]}), do: literal
  defp unwrap(other), do: other
end
