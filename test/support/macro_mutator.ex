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
  A **free-standing fragment builder** (`dyn(x > min + 1)`) — the analog of Ecto's
  `dynamic/1,2`: a macro in ordinary expression position whose condition argument is opaque DSL
  (registered `:skip` by `Mutare.Test.SubcontractNodeMutator`, so core keeps it raw), yet whose
  value is the condition itself — so a whole-call rewrite is observable at runtime. A real,
  loadable `defmacro` so a bare `import Mutare.Test.QueryDSL` resolves it by reflection.
  """
  defmacro dyn(condition) do
    quote do: unquote(condition)
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
  `c:Mutare.MacroRouting.macro_routes/0` extension point and the `:skip` argument treatment.

  It registers `Mutare.Test.QueryDSL.query/1` as a known macro whose argument is
  `:skip`ped — so Mutare core never mutates the DSL body — and mutates the query
  itself with DSL knowledge: dropping the last clause (the analog of removing a
  `where`). One module carries both the registration and the mutation, so a project
  enables it with a single `:mutators` entry and core stays DSL-agnostic.
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.MacroRouting

  @impl Mutare.Mutator
  def name, do: :query_dsl

  @impl Mutare.MacroRouting
  def macro_routes, do: [{Mutare.Test.QueryDSL, :query, 1, :skip}]

  @impl Mutare.Mutator
  # A `query([clause, clause, ...])` with more than one clause — drop the last one.
  # Reuses the surviving clause AST, so the mutant is compile-safe.
  def mutate({:query, meta, [clauses]}) when is_list(clauses) and length(clauses) > 1 do
    {_dropped, kept} = List.pop_at(clauses, -1)
    [{:query, meta, [kept]}]
  end

  def mutate(_node), do: :skip
end

defmodule Mutare.Test.SubcontractNodeMutator do
  @moduledoc """
  A **node-level sub-contracting** mutator — the free-standing-`dynamic` pattern, the whole-call
  twin of `Mutare.Test.SubcontractHostMutator`: it registers `Mutare.Test.QueryDSL.dyn/1` with a
  `:skip` argument (core keeps the condition raw) and delivers through plain `mutate/2` — no
  `host/2`, no weave. Its own foreign-semantics catalog contributes only the comparison
  reversal; every mutant *inside* the comparison's right operand (the island) comes from
  `Mutare.Analyze.expression_mutations/3` over `context.mutators` — present because the offer is
  the whole-call offer of a registered macro. Each relay is a `%Mutare.Mutator.Mutation{}` with
  `producer:` set, so its Site (and `# mutare:ignore` vocabulary) belongs to the producing core
  family; delivery is the ordinary in-place selector on the rebuilt call.
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.MacroRouting

  alias Mutare.Mutator.Mutation

  @comparisons [:>, :<, :>=, :<=]

  @impl Mutare.Mutator
  def name, do: :node_sub

  @impl Mutare.MacroRouting
  def macro_routes, do: [{Mutare.Test.QueryDSL, :dyn, 1, :skip}]

  @impl Mutare.Mutator
  def mutate({:dyn, meta, [{op, cmeta, [left, right]}]}, context) when op in @comparisons do
    reversal = {:dyn, meta, [{reverse(op), cmeta, [left, right]}]}

    islands =
      for {spec, mutated, note, variant} <-
            Mutare.Analyze.expression_mutations(right, Map.get(context, :mutators, []), context) do
        Mutation.new({:dyn, meta, [{op, cmeta, [left, mutated]}]},
          producer: spec,
          note: note,
          variant: variant
        )
      end

    [reversal | islands]
  end

  def mutate(_node, _context), do: :skip

  defp reverse(:>), do: :<
  defp reverse(:<), do: :>
  defp reverse(:>=), do: :<=
  defp reverse(:<=), do: :>=
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

  The whole-call mutant carries **both** a `note` and a `# mutare:ignore` `variant` label (a
  `%Mutare.Mutator.Mutation{}` with the family opting in via `variants/0`), so the tests pin that
  *each* rides through the whole-call **re-home** — the path that turns the call's
  `Candidate.InPlace` into a `Candidate.MacroPattern` — onto the `Mutare.Site`. (Each was silently
  dropped in turn: the note when `MacroPattern` had no `note` field, the variant when it had no
  `variant` field — the latter leaving a valid `[unpack_call:value]` directive unable to suppress it.)
  """
  @behaviour Mutare.Mutator
  @behaviour Mutare.MacroRouting

  alias Mutare.Mutator.Mutation

  @note "whole-call mutant — bindings still escape"
  @variant "value"

  @impl Mutare.Mutator
  def name, do: :unpack_call

  # Opt into the variant-label system so the tagged whole-call mutant's `value` label is recorded
  # (and a `[unpack_call:value]` qualifier validates against this vocabulary).
  @impl Mutare.Mutator
  def variants, do: ~w(value)

  @impl Mutare.MacroRouting
  def macro_routes, do: [{Mutare.Test.QueryDSL, :unpack, 2, [:binding_pattern, :expression]}]

  @impl Mutare.Mutator
  # `unpack(pattern, value)` (directly written) — replace the value, keeping the pattern.
  def mutate({:unpack, meta, [pattern, _value]}),
    do: [tagged({:unpack, meta, [pattern, [9, 9]]})]

  # `unpack(value)` (a `|>` stage — the pattern is the piped LHS) — replace the visible value.
  def mutate({:unpack, meta, [_value]}),
    do: [tagged({:unpack, meta, [[9, 9]]})]

  def mutate(_node), do: :skip

  # The whole-call mutant carrying both a note and the `value` variant tag — so the tests can pin
  # that the re-home preserves each.
  defp tagged(node), do: %Mutation{node: node, note: @note, variant: @variant}
end
