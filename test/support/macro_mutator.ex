defmodule Mutare.Test.QueryDSL do
  @moduledoc """
  A tiny fake query DSL used in tests: a `query/1` macro whose keyword argument is
  an opaque DSL body (the analog of `Ecto.Query.from`). It is a real, loadable
  macro so a whole `import Mutare.Test.QueryDSL` resolves by reflection, exercising
  the bare-call known-macro path end to end.
  """

  @doc "Expand to the clause list verbatim — enough that a metamutant using it compiles."
  defmacro query(clauses) do
    quote do: unquote(clauses)
  end

  @doc """
  A pipeable stage (`query |> where(condition)`) — the query-builder shape, where the
  piped value is the first effective argument and the condition is an opaque DSL body.
  """
  defmacro where(query, _condition) do
    quote do: unquote(query)
  end

  @doc """
  A **binding-escaping** macro (`unpack([a, b], value)`) — expands to a plain `=` match,
  so its pattern's variables bind into the *enclosing* scope (the user-macro analog of
  `Kernel.destructure`). Registered `:binding_pattern`, it earns structural pattern
  mutants (swap/wildcard) on its pattern arg in a value-discarded position. A real,
  loadable `defmacro` so a bare `import Mutare.Test.QueryDSL` resolves it by reflection.
  """
  defmacro unpack(pattern, value) do
    quote do: unquote(pattern) = unquote(value)
  end

  @doc """
  Like `unpack/2` but with the **value first and the pattern second** — so a registered routing
  is `[:expression, :binding_pattern]` and, piped as `value |> unpack2([x, y])`, the binding
  pattern is a *visible* argument rather than the piped value.
  """
  defmacro unpack2(value, pattern) do
    quote do: unquote(pattern) = unquote(value)
  end
end

defmodule Mutare.Test.SchemaDSL do
  @moduledoc """
  A fake module-level **block** DSL: a `schema do … end` macro whose `do` body is an
  opaque DSL (the analog of `Ecto.Schema`'s `schema`). Used to test that a registered
  `:skip` keeps Mutare core out of a *module-level* macro block body — the
  `Mutare.Transform.Analyze.analyze_module_macro_block/2` path, which is distinct from
  the runtime/argument macro path. A real, loadable `defmacro schema/1` so a bare
  `import Mutare.Test.SchemaDSL` resolves by reflection.
  """

  @doc """
  Discard the body — enough that a metamutant using it compiles whatever the (skipped,
  raw) body contains. A real module-level macro that *defines a function*, mirroring how
  a schema DSL generates code from an opaque block.
  """
  defmacro schema(do: _body) do
    quote do: def(__fields__, do: [])
  end
end

defmodule Mutare.Test.QueryMutator do
  @moduledoc """
  A reference **macro-aware** custom mutator, used in tests to exercise the
  `c:Mutare.Mutator.MacroAware.macros/0` extension point and the `:skip` argument treatment.

  It registers `Mutare.Test.QueryDSL.query/1` as a known macro whose argument is
  `:skip`ped — so Mutare core never mutates the DSL body — and mutates the query
  itself with DSL knowledge: dropping the last clause (the analog of removing a
  `where`). One module carries both the registration and the mutation, so a project
  enables it with a single `:mutators` entry and core stays DSL-agnostic.
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.Mutator.MacroAware

  @impl Mutare.Mutator
  def name, do: :query_dsl

  @impl Mutare.Mutator.MacroAware
  def macros, do: [{Mutare.Test.QueryDSL, :query, 1, :skip}]

  @impl Mutare.Mutator
  # A `query([clause, clause, ...])` with more than one clause — drop the last one.
  # Reuses the surviving clause AST, so the mutant is compile-safe.
  def mutate({:query, meta, [clauses]}) when is_list(clauses) and length(clauses) > 1 do
    {_dropped, kept} = List.pop_at(clauses, -1)
    [{:query, meta, [kept]}]
  end

  def mutate(_node), do: :skip
end

defmodule Mutare.Test.UnpackMutator do
  @moduledoc """
  A **macro-aware** custom mutator for a *binding-escaping* macro, used in tests to exercise
  the interaction between a whole-call mutation and the structural pattern mutants.

  It registers `Mutare.Test.QueryDSL.unpack/2` as `:binding_pattern` (so core mutates its
  pattern arg with swap/wildcard) **and** mutates the *whole call* — replacing the value
  argument with an arbitrary observable literal. Both kinds of mutant target the same
  binding-escaping call, so the transform must deliver them through the one tuple-export
  selector: the whole-call mutant must not be silently shadowed (the direct form) nor spliced
  as `pattern |> case …` (the piped form).

  The whole-call mutant carries a **note** (a `%Mutare.Mutator.Mutation{}`), so the tests also
  pin that a `mutate/1`-supplied advisory rides through the whole-call **re-home** — the path
  that turns the call's `Candidate.InPlace` into a `Candidate.MacroPattern` — onto the
  `Mutare.Site` (it was silently dropped when `MacroPattern` had no `note` field).
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.Mutator.MacroAware

  alias Mutare.Mutator.Mutation

  @note "whole-call mutant — bindings still escape"

  @impl Mutare.Mutator
  def name, do: :unpack_call

  @impl Mutare.Mutator.MacroAware
  def macros, do: [{Mutare.Test.QueryDSL, :unpack, 2, [:binding_pattern, :expression]}]

  @impl Mutare.Mutator
  # `unpack(pattern, value)` (directly written) — replace the value, keeping the pattern.
  def mutate({:unpack, meta, [pattern, _value]}),
    do: [Mutation.new({:unpack, meta, [pattern, [9, 9]]}, @note)]

  # `unpack(value)` (a `|>` stage — the pattern is the piped LHS) — replace the visible value.
  def mutate({:unpack, meta, [_value]}),
    do: [Mutation.new({:unpack, meta, [[9, 9]]}, @note)]

  def mutate(_node), do: :skip
end
