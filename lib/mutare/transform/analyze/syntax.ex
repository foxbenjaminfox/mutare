defmodule Mutare.Transform.Analyze.Syntax do
  @moduledoc false

  # The block-key vocabulary the analyze dispatch and its handler submodules share —
  # `do_key?`/`clause_block_key?`/`block_key?` — with **no dependency on the descent**. Kept
  # here (not as `Mutare.Transform.Analyze` predicates the handlers call back into) so they are a
  # one-way leaf rather than a module cycle. (The other cross-module reader, the known-macro
  # routing stamp, already lives in `Mutare.Transform.Meta.macro_routing/1`.)

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
end
