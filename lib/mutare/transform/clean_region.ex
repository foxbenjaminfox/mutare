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
  # `Mutare.Manifest` reads this `case` as a selector hosting no mutant: neither clause
  # pattern is a positive integer, so it contributes no region.
  #
  # Two deliveries build regions: a lifted group's dispatcher chooses between its base
  # clauses and a relocated clean clause group (`Mutare.Transform.LiftedEmit`), and a
  # clause that stays in place chooses between two `:do` bodies inside its own function
  # (`Mutare.Transform`). `Mutare.Transform.CleanPath` decides whether the source may be
  # copied at all; `worthwhile?/2` whether a copy repays its code.

  alias Mutare.AST
  alias Mutare.Coverage.Recorder
  alias Mutare.Transform.{CleanPath, GuardBuild}

  defmodule Decision do
    @moduledoc false

    # What the emitter decided for one candidate region, and why. `variants` counts the
    # mutants actually emitted inside it, `sites` the selector reads and dispatch gates
    # they were delivered through. Read by `bench/clean_eligibility.exs`; the transform
    # itself never consults a recorded decision.
    @type t :: %__MODULE__{
            function: {atom(), arity()},
            delivery: :lifted | :in_place,
            line: pos_integer() | nil,
            variants: non_neg_integer(),
            sites: non_neg_integer(),
            verdict: :clean | :below_threshold | {:ineligible, CleanPath.reason()}
          }

    @enforce_keys [:function, :delivery, :line, :variants, :sites, :verdict]
    defstruct @enforce_keys
  end

  @typedoc "An inclusive interval of runtime (namespace-local) mutant ids."
  @type range :: {pos_integer(), pos_integer()}

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

  @doc """
  The region `case`: `instrumented` for baseline and for an active id inside `range`,
  `clean` otherwise. `var` must already be bound to the active id where the result lands.

  The guard uses only special forms and explicit `:erlang` calls, like every generated
  operator (`Mutare.Transform.GuardBuild`).
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
end
