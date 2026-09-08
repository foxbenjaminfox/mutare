defmodule Mutare.Transform.Analyze.Syntax do
  @moduledoc false

  # The block-key vocabulary the analyze dispatch and its handler submodules share —
  # `do_key?`/`clause_block_key?`/`block_key?` — with **no dependency on the descent**. Kept
  # here (not as `Mutare.Transform.Analyze` predicates the handlers call back into) so they are a
  # one-way leaf rather than a module cycle. (The other cross-module reader, the known-macro
  # routing stamp, already lives in `Mutare.Transform.Meta.routing/1`.)

  alias Mutare.AST

  # The try-style body blocks whose clause bodies are *return paths*
  # (`rescue`/`catch`/`else`). Their left side is always a match, and their tails
  # return — unlike `:after`, whose value `try` discards (so it is no return path
  # and is left to mutate only in place, like `:do`).
  @clause_block_keys [:rescue, :catch, :else]

  # The keyword atoms that render a construct's `do … end` block (`do:` plus the
  # `else`/`rescue`/`catch`/`after` tails). As *block* syntax these keys carry no
  # `format: :keyword` marker, so `block_key?/1` recognises them by atom — protecting
  # a key like `do:` from being mutated (which would not even render).
  @block_keys [:do, :else, :rescue, :catch, :after]

  @doc """
  Whether `key` names a `:do` block. Shared by clause-block routing
  (`Analyze.DefClause.normalize_clause_blocks/1`, `analyze_do_blocks/3`), the trailing-keyword
  `do:` guard, and `Mutare.Transform.Analyze.Returns` (which classifies the `:do` tail as a
  return path) — the one home for the predicate rather than reclassifying the atom.
  """
  @spec do_key?(Macro.t()) :: boolean()
  def do_key?(key), do: AST.key_atom(key) == :do

  @doc """
  Whether `key` names a try-style clause block whose tails are *return paths*
  (`rescue`/`catch`/`else`) — distinct from `:after`, whose value `try` discards. This is the
  canonical return-path set; `Mutare.Transform.Analyze.Returns` shares the one predicate for its
  tail classification rather than reclassifying the same atoms.
  """
  @spec clause_block_key?(Macro.t()) :: boolean()
  def clause_block_key?(key), do: AST.key_atom(key) in @clause_block_keys

  @doc """
  Whether `key` names a `do … end` block key (`do:`/`else:`/`rescue:`/`catch:`/`after:`) — a
  pure structural label, never a runtime value to mutate. The descent's keyword-pair clause and
  the module-macro-block routing use it to keep a block key raw.
  """
  @spec block_key?(Macro.t()) :: boolean()
  def block_key?(key), do: AST.key_atom(key) in @block_keys

  @doc """
  A non-empty list of `->` clauses — a `case`/`cond`/`receive` `do:`, a `rescue`/`catch`/
  `else` body, a `reduce:` comprehension `do:`. Only arrow clauses parse to this shape
  (`[a -> b]` is a syntax error, so a genuine list literal never contains a `->`).
  """
  @spec clause_list?(Macro.t()) :: boolean()
  def clause_list?(list),
    do: is_list(list) and list != [] and Enum.all?(list, &match?({:->, _, _}, &1))

  @doc """
  Unwrap every **keyword-form** clause tail in a construct's block keyword — the parse of
  `case x, do: (p -> b)` / `cond(do: (c -> b))` / `try(…, rescue: (p -> b))` /
  `receive(do: (p -> b), after: (t -> b))` / `def f, do: …, rescue: (p -> b)` — so downstream
  consumers see one shape, the bare clause list the block form always carries. The wrapper —
  `{key, {:__block__, _, [clauses]}}` — is otherwise indistinguishable from a *list literal*
  in that keyword's value, so shape-based clause routing misses it: the clause machinery
  (`cond` condition analysis, `case` per-clause tupling, `rescue` narrowing, receive-clause
  variants, return tails) is `is_list`-guarded and silently skips the keyword form, and a
  runtime descent would offer the wrapper to the `List` family (collapsing required `->`
  clauses to `[]` — poison). Unwrapping is safe on shape alone: only arrow clauses parse to a
  block whose sole child is a `clause_list?/1`, and the final render flips block keys back to
  plain atoms, at which point Sourceror renders the construct in block form. A block-form
  value is already a bare list (no-op), and non-block keys and non-clause values pass through.
  """
  @spec normalize_clause_blocks(Macro.t()) :: Macro.t()
  def normalize_clause_blocks(blocks) when is_list(blocks) do
    Enum.map(blocks, fn
      {key, {:__block__, _meta, [clauses]}} = pair ->
        if block_key?(key) and clause_list?(clauses), do: {key, clauses}, else: pair

      other ->
        other
    end)
  end

  def normalize_clause_blocks(other), do: other
end
