defmodule Mutare.Transform.CleanRegion do
  @moduledoc false

  # One decision, made where a region of generated code begins, that the active mutant
  # cannot be inside it — in place of the same decision at every selector the region
  # holds. A region is a contiguous id interval plus two implementations of one piece of
  # source: the instrumented one the emit walk produced, and the source itself.
  #
  #     case mutare_active do
  #       _ when mutare_active == 0 or (is_integer(mutare_active) and
  #                first <= mutare_active and mutare_active <= last) ->
  #         <instrumented>
  #
  #       _ ->
  #         <the source, uninstrumented>
  #     end
  #
  # Baseline and probe (id zero) keep the instrumented implementation, so coverage
  # positions and their timing are unchanged. The interval is deliberately conservative:
  # an exclusion needs the exact id set, whereas choosing the slower implementation for an
  # ignored, unselected, or poisoned hole costs only time. Another file's selection
  # projects to `:inactive` (`Mutare.Metamutant.subject_ast/1`) and takes the clean branch.
  #
  # Two deliveries build regions: a lifted group's dispatcher chooses between its base
  # clauses and a relocated clean clause group (`Mutare.Transform.LiftedEmit`, named by
  # `relocated_name/1`), and a clause that stays in place chooses between two `:do` bodies
  # inside its own function (`Mutare.Transform`).
  #
  # **Any source may be copied.** The transform does not ask what a call in it is — a
  # function, a macro, a zero-arity macro that reads as a variable. A copy that does not
  # compile is *attributable* instead: the interval in the guard is the region's identity,
  # `read/2` reads it back, `Mutare.Manifest` records the copy's lines under it, and poison
  # recovery drops the region (`Config.skip_regions`) and rebuilds, as it drops a mutant.
  # Dropping one loses no mutant, only the faster path. A copy that compiles but observes
  # that it is a copy (its expansion count, `__ENV__.function`, a stack frame) is the
  # target's concern, as it already is under lifting. `worthwhile?/2` is the one policy:
  # whether a copy repays its code.

  alias Mutare.AST
  alias Mutare.Coverage.Recorder
  alias Mutare.Transform.GuardBuild

  defmodule Decision do
    @moduledoc false

    # What the emitter decided for one candidate region. `variants` counts the mutants
    # actually emitted inside it, `sites` the selector reads and dispatch gates they were
    # delivered through, `range` the region's identity. `Mutare.Transform.Invariants`
    # checks that every `:clean` decision can be read back; nothing else in the transform
    # consults a recorded decision.
    @type t :: %__MODULE__{
            function: {atom(), arity()},
            delivery: :lifted | :in_place,
            line: pos_integer() | nil,
            variants: non_neg_integer(),
            sites: non_neg_integer(),
            range: Mutare.Transform.CleanRegion.range(),
            verdict: :clean | :below_threshold | :dropped
          }

    @enforce_keys [:function, :delivery, :line, :variants, :sites, :range, :verdict]
    defstruct @enforce_keys
  end

  @typedoc """
  An inclusive interval of runtime (namespace-local) mutant ids. It is also the region's
  identity within its file: regions claim disjoint ids, the transform writes the interval
  into the region's guard, and ids are stable across poison rebuilds.
  """
  @type range :: {pos_integer(), pos_integer()}

  @typedoc """
  A region `case` as read back: its identity, its clean branch, and — for a lifted
  dispatcher — the `{name, arity}` its clean clauses were relocated under.
  """
  @type read :: %{
          range: range(),
          instrumented: Macro.t(),
          clean: Macro.t(),
          relocated: {atom(), arity()} | nil
        }

  @doc """
  Whether a region holding `sites` selector sites repays a clean implementation.

  The decision itself costs about what one inactive selector does (a few comparisons on
  an already-bound id), so a region of one site has nothing to win; from two sites on, the
  clean implementation runs faster per activation (NOTES "Clean regions"). The copy's cost
  is code: it is no larger than the source it copies, which the instrumented implementation
  beside it already dwarfs.
  """
  @spec worthwhile?(non_neg_integer(), pos_integer()) :: boolean()
  def worthwhile?(sites, threshold), do: sites >= threshold

  @doc "The private name a lifted group's clean clauses are relocated under."
  @spec relocated_name(atom()) :: atom()
  def relocated_name(base), do: :"#{base}_original"

  @doc """
  The region `case`: `instrumented` for baseline and for an active id inside `range`,
  `clean` otherwise. `var` must already be bound to the active id where the result lands.

  The guard uses only special forms and explicit `:erlang` calls, like every generated
  operator (`Mutare.Transform.GuardBuild`). `read/2` is its inverse; the two move together.
  """
  @spec select(atom(), range(), Macro.t(), Macro.t()) :: Macro.t()
  def select(var, {first, last}, instrumented, clean) do
    active = Recorder.catch_all_pattern(var)

    inside =
      AST.erlang_call(:andalso, [
        AST.erlang_call(:is_integer, [active]),
        AST.erlang_call(:andalso, [
          AST.erlang_call(:>=, [active, AST.literal(first)]),
          AST.erlang_call(:"=<", [active, AST.literal(last)])
        ])
      ])

    guard = AST.erlang_call(:orelse, [GuardBuild.gate(0, var), inside])

    {:case, [],
     [
       active,
       [
         do: [
           {:->, [], [[{:when, [], [{:_, [], nil}, guard]}], instrumented]},
           {:->, [], [[{:_, [], nil}], clean]}
         ]
       ]
     ]}
  end

  @doc """
  Read a region `case` back out of a parsed metamutant, given the file's dispatch variable;
  `:error` for any other node. Tolerant of the literal and keyword-key wrapping a
  Sourceror-style parse adds.

  A lifted dispatcher is told from an in-place body by what `LiftedEmit` wrote: the
  instrumented branch ends in a call to `<base>` that threads the dispatch variable, and
  the clean branch is a call to `relocated_name(<base>)`. A source body that merely is a
  local call never has that name.
  """
  @spec read(Macro.t(), atom()) :: {:ok, read()} | :error
  def read({:case, _meta, [{var, _var_meta, context}, blocks]}, var)
      when is_atom(context) and is_list(blocks) do
    with [{key, clauses}] <- blocks,
         :do <- AST.key_atom(key),
         [
           {:->, _, [[{:when, _, [{:_, _, _}, guard]}], instrumented]},
           {:->, _, [[{:_, _, wildcard}], clean]}
         ]
         when is_atom(wildcard) <- clauses,
         {:ok, range} <- read_guard(guard, var) do
      {:ok,
       %{
         range: range,
         instrumented: instrumented,
         clean: clean,
         relocated: relocated(instrumented, clean, var)
       }}
    else
      _ -> :error
    end
  end

  def read(_node, _var), do: :error

  defp read_guard(guard, var) do
    with {:ok, [baseline, inside]} <- AST.erlang_call_args(guard, :orelse),
         {:ok, [{^var, _, _}, zero]} <- AST.erlang_call_args(baseline, :"=:="),
         {:ok, 0} <- AST.literal_value(zero),
         {:ok, [_is_integer, bounds]} <- AST.erlang_call_args(inside, :andalso),
         {:ok, [lower, upper]} <- AST.erlang_call_args(bounds, :andalso),
         {:ok, [{^var, _, _}, first_node]} <- AST.erlang_call_args(lower, :>=),
         {:ok, [{^var, _, _}, last_node]} <- AST.erlang_call_args(upper, :"=<"),
         {:ok, first} when is_integer(first) <- AST.literal_value(first_node),
         {:ok, last} when is_integer(last) <- AST.literal_value(last_node) do
      {:ok, {first, last}}
    else
      _ -> :error
    end
  end

  defp relocated(instrumented, {name, _meta, args}, var) when is_atom(name) and is_list(args) do
    case instrumented |> statements() |> List.last() do
      {base, _call_meta, [{^var, _, _} | _rest]} when is_atom(base) ->
        if relocated_name(base) == name, do: {name, length(args)}

      _other ->
        nil
    end
  end

  defp relocated(_instrumented, _clean, _var), do: nil

  defp statements({:__block__, _meta, statements}), do: statements
  defp statements(statement), do: [statement]
end
