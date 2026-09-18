defmodule Mutare.Transform.LiftedEmit do
  @moduledoc false

  # The **AST-assembly half of lifting**: builds the public dispatcher and the gated base
  # clauses for a lifted function group, given the already-claimed candidate ids. Pure — no
  # `Ctx`, no id-claiming. `Mutare.Transform.emit_function_plan/2` owns the stateful half
  # (threading `Ctx`, claiming ids via `SelectorEmit.claim_items/4`, emitting in-place body
  # selectors) and calls `assemble/7` with plain data: the plan, the emitted source clauses, the
  # `{id, index, clause, witness}` claims, the group number, the config, and prepared
  # coverage expressions, and an optional complete function id interval for a clean path.
  #
  # The interleaving scheme: each source clause's mutant clauses (gated `when <var> === <id>`)
  # precede the source clause itself (gated `when <var> !== <those ids>`), so exactly one wins
  # per `(id, args)` — the per-clause `C+M` lifting (see `Mutare.Transform.FunctionPlan` and
  # NOTES "lifting blowup"). A candidate that changes the head patterns gets a clause of its
  # own. A clause's **guard-only** variants share one: their patterns and raw body are the
  # source clause's, so they differ in the guard alone and become its `when` alternatives,
  # each gated on its own id (`lifted_guard_group/3`) — one copy of the body where there was
  # one per mutant.
  # An eligible clean path adds C raw original clauses, for 2C+M total; it never
  # duplicates a whole group per mutant. Pure self-recursion can remain in that copy.

  alias Mutare.Coverage.Recorder
  alias Mutare.Metamutant

  alias Mutare.Transform.{
    CleanPath,
    CleanRegion,
    ClauseAST,
    Config,
    FunctionPlan,
    GuardBuild,
    ImportWitness,
    Super
  }

  # The fixed facts of one lifted group, derived once in `assemble/7` and read by every clause
  # builder below: the public signature (`vis`/`name`/`arity` — the dispatcher keeps the real
  # name), the private `base` name the clauses are relocated under, the dispatch variable `var`
  # (`Config.active_var`) and the file's runtime `namespace` for the active-id read,
  # and `super_var` — the super-forwarding closure variable, non-`nil` only when a
  # lifted body calls `super` (see `build_dispatcher/3`).
  defmodule Group do
    @moduledoc false
    @enforce_keys [:vis, :name, :arity, :base, :var, :namespace, :super_var]
    defstruct @enforce_keys
  end

  @typep claim :: {pos_integer(), FunctionPlan.variant(), ImportWitness.witness_set()}

  @doc """
  The lifted function group as emitted: the public dispatcher followed by the interleaved base
  clauses (`build_base_clauses/3`). `orig_clauses` are the source clauses with their in-place
  body selectors already emitted; `claimed` the `{id, variant, witness}` claims
  (`t:FunctionPlan.variant/0`); `group_number` the file-wide lifted-group counter (for a
  collision-free base name). A `:guard` variant is a statement that its mutant may share a
  clause with its siblings; the caller hands over a `:clause` variant for one that may not. `records` are the dispatcher's coverage expressions, prepared by the
  stateful emitter; assembly does not choose their gate or track scope usage.

  A non-nil `active_range` adds one raw original clause group and routes mutations
  outside that interval to it. The caller must include **all** function ids, including
  body mutations, and establish `CleanPath.eligible?/1` before supplying the range.
  Baseline keeps the instrumented path so coverage positions remain unchanged.
  """
  @spec assemble(
          FunctionPlan.t(),
          [Macro.t()],
          [claim()],
          non_neg_integer(),
          Config.t(),
          [Macro.t()],
          {pos_integer(), pos_integer()} | nil
        ) ::
          [Macro.t()]
  def assemble(
        %FunctionPlan{signature: {vis, name, arity}} = plan,
        orig_clauses,
        claimed,
        group_number,
        %Config{} = config,
        records,
        active_range \\ nil
      ) do
    group = %Group{
      vis: vis,
      name: name,
      arity: arity,
      base: :"#{base_name(name, arity, group_number, config.prefix)}",
      var: config.active_var,
      namespace: config.runtime_namespace,
      # If any lifted body calls `super`, the relocated base copies can't (super is legal only
      # in the overriding function): the dispatcher binds a forwarding closure and threads it.
      super_var: if(Super.in_clauses?(plan.clauses), do: config.super_var, else: nil)
    }

    # Default arguments (`def f(a, b \\ 1)`) expand to multiple arities. They stay on the
    # public dispatcher — which keeps the original arity contract — while the base function
    # takes the full arity with `\\` stripped (`clause_parts/1`). The default *expressions* are
    # taken from the already-emitted clauses, so their in-place selectors ride along and the
    # dispatcher keeps mutating its defaults.
    defaults = clause_defaults(orig_clauses)

    [build_dispatcher(group, records, defaults, active_range)] ++
      build_base_clauses(group, plan, orig_clauses, claimed) ++
      clean_clauses(group, plan, active_range)
  end

  @doc """
  The active-id read `<var> = :persistent_term.get(...)`: the dispatch variable bound once so the
  body's hoisted selectors read it (`Mutare.Transform.SelectorEmit.subject/1`). The single home for
  the read's shape, shared by the lifted dispatcher (here) and a non-lifted function's `:do`-block
  prologue (`Mutare.Transform`).
  """
  @spec active_read(atom(), String.t() | nil) :: Macro.t()
  def active_read(var, namespace \\ nil),
    do: {:=, [], [Recorder.catch_all_pattern(var), Metamutant.subject_ast(namespace)]}

  # The lifted function's base clauses, interleaved: for each source clause, its mutant clauses
  # (gated `when <var> === <id>`) come *before* the source clause itself (gated `when <var> !==
  # <those ids>`, so it steps aside when a mutant is active). A dropped clause contributes only
  # its exclusion (no mutant clause); a bodiless header contributes neither — its defaults ride
  # on the dispatcher and it has no body to lift.
  defp build_base_clauses(%Group{} = group, plan, orig_clauses, claimed) do
    # One grouping by source clause, not a scan of all M candidates per clause. Every claimed
    # candidate overrides (guard/literal/structure) or drops its clause, so the group *is* both
    # the clause's mutant clauses and the id set excluding its original version.
    by_clause = Enum.group_by(claimed, fn {_id, variant, _witness} -> elem(variant, 1) end)

    orig_clauses
    |> Enum.with_index()
    |> Enum.flat_map(fn {orig, index} ->
      claims = Map.get(by_clause, index, [])

      mutant_clauses =
        claims
        |> deliveries(plan)
        |> Enum.map(fn
          {:own, id, clause, witness} -> lifted_mutant(group, id, clause, witness)
          {:shared, members} -> lifted_guard_group(group, plan, members)
        end)

      if ClauseAST.bodiless_header?(orig) do
        mutant_clauses
      else
        excluded = Enum.map(claims, fn {id, _variant, _witness} -> id end)
        mutant_clauses ++ [lifted_original(group, orig, excluded)]
      end
    end)
  end

  # One source clause's claims as the mutant clauses to emit, in claim order: `{:own, id,
  # clause, witness}` for a clause of one mutant, `{:shared, members}` for two or more guard
  # variants delivered as one. A drop emits nothing.
  #
  # Guard variants share a clause only with an **equal import witness**. The witness is
  # spliced into the shared body, so a hidden import conflict there fails the compile on a
  # line that belongs to every member — correct only when every member carries that witness.
  # (Almost always all `nil`: a guard operator is rarely a bare imported call.)
  #
  # The shared clause stands where its first member stood and later members are skipped, so
  # a function with no group of two renders exactly as it did: mutant clauses of one source
  # clause are gated on distinct ids, and their relative order decides nothing.
  defp deliveries(claims, plan) do
    shared =
      claims
      |> Enum.filter(&match?({_id, {:guard, _index, _guards}, _witness}, &1))
      |> Enum.group_by(fn {_id, _variant, witness} -> witness end)
      |> Map.filter(fn {_witness, members} -> match?([_, _ | _], members) end)

    Enum.flat_map(claims, fn
      {_id, {:drop, _index}, _witness} ->
        []

      {id, {:clause, _index, clause}, witness} ->
        [{:own, id, clause, witness}]

      {id, {:guard, index, guards}, witness} = claim ->
        case shared do
          %{^witness => [^claim | _later] = members} -> [{:shared, members}]
          %{^witness => _members} -> []
          %{} -> [{:own, id, FunctionPlan.guard_clause(plan, index, guards), witness}]
        end
    end)
  end

  # The public dispatcher: read the active mutant id once, record coverage for the group's lifted
  # ids (inert off the probe — see `Mutare.Coverage.Recorder`), then tail-call the lifted function
  # with the id threaded as the extra first argument.
  #
  #     def f(mutare_arg1, mutare_arg2 \\ <default>, ...) do
  #       mutare_active = :persistent_term.get(:mutare_active, 0)
  #       <record ids>
  #       <base>(mutare_active, mutare_arg1, mutare_arg2, ...)
  #     end
  #
  # `defaults` (position → expression, from the source's default args) is overlaid onto the
  # dispatcher *head* — so the public function keeps the original multi-arity contract — while the
  # call to the base passes the *plain* vars (the defaults are already resolved by the time the
  # head's body runs). The base therefore always sees the full arity.
  #
  # `super_var` (non-`nil` only when a lifted body calls `super`) adds a closure
  # `<super_var> = &super/arity` bound here — `super` is legal inside the dispatcher (the
  # overriding function), even captured — and threaded to the base as its second argument, so the
  # relocated body can call `super` through it (`Mutare.Transform.Super`).
  defp build_dispatcher(%Group{} = group, records, defaults, active_range) do
    call_args = dispatcher_args(group.arity)
    head_args = with_defaults(call_args, defaults)
    var_node = Recorder.catch_all_pattern(group.var)
    read = active_read(group.var, group.namespace)

    {super_args, super_stmts} = super_closure_binding(group.super_var, group.arity)
    call = {group.base, [], [var_node | super_args] ++ call_args}

    statements = super_stmts ++ records ++ [call]

    body =
      if active_range do
        # Ids outside the group's interval (and another file's `:inactive` projection)
        # call the raw clauses; see `Mutare.Transform.CleanRegion`.
        instrumented = {:__block__, [], statements}
        clean = {clean_name(group), [], call_args}
        {:__block__, [], [read, CleanRegion.select(group.var, active_range, instrumented, clean)]}
      else
        {:__block__, [], [read | statements]}
      end

    {group.vis, [], [{group.name, [], head_args}, [do: body]]}
  end

  defp clean_clauses(_group, _plan, nil), do: []

  defp clean_clauses(group, plan, _range) do
    direct_recursion? = CleanPath.pure_self_recursive?(plan)

    for clause <- plan.clauses, not ClauseAST.bodiless_header?(clause) do
      {meta, call_meta, args, guards, body} = clause_parts(clause)

      body =
        if direct_recursion?,
          do:
            CleanPath.redirect_self_calls(body, {group.name, group.arity}, clean_name(group), []),
          else: body

      call = {clean_name(group), call_meta, args}
      guard = GuardBuild.combine(guards)
      head = if guard, do: {:when, [], [call, guard]}, else: call
      {:defp, meta, [head | body]}
    end
  end

  defp clean_name(group), do: :"#{group.base}_original"

  # The default-argument expressions of a lifted group, keyed by 0-based head position. They live
  # on exactly one source clause — a bodiless header in a multi-clause group, or the lone clause
  # of a single-clause group — so the first clause carrying any `\\` supplies them all. The
  # expressions come straight from the *emitted* clauses, so their in-place default-value
  # selectors are intact and the dispatcher that hosts them keeps mutating the defaults at call
  # time.
  defp clause_defaults(clauses) do
    Enum.find_value(clauses, %{}, fn clause ->
      defaults =
        clause
        |> ClauseAST.head_args()
        |> Enum.with_index()
        |> Enum.flat_map(fn
          {{:\\, _meta, [_pattern, default]}, pos} -> [{pos, default}]
          _arg -> []
        end)
        |> Map.new()

      if map_size(defaults) > 0, do: defaults, else: nil
    end)
  end

  @doc """
  Private base name for a lifted group. `prefix` is the file's collision-free generated-name
  prefix (`Ctx.prefix`, normally `"__mutare_"`); the trailing `g<group>` keeps generated names
  unique across groups; `?`/`!` (valid only at the end of a function name) are replaced so the
  sanitized base is a legal identifier (e.g. `ok?` → `__mutare_ok__1_g1`). The public dispatcher
  keeps the real name (including any `?`/`!`).

  Public because the test suite's rendered-name pins (`Mutare.Test.Metamutant.lifted_name/4`)
  derive from it, so a change to the composition moves every assertion with it.
  """
  @spec base_name(atom(), arity(), non_neg_integer(), String.t()) :: String.t()
  def base_name(name, arity, group, prefix) do
    sanitized = name |> Atom.to_string() |> String.replace(["?", "!"], "_")
    "#{prefix}#{sanitized}_#{arity}_g#{group}"
  end

  # The super-forwarding closure binding for the dispatcher, plus the extra call arg that
  # threads it to the base: `{[<super_var>], [<super_var> = &super/arity]}` when the group uses
  # `super`, else `{[], []}` (unchanged dispatcher). `&super/arity` is exactly
  # `fn a1, …, aN -> super(a1, …, aN) end` — `super`'s only legal arity is the full param count,
  # so the single capture forwards every legal call — but needs no synthesised arg list.
  defp super_closure_binding(nil, _arity), do: {[], []}

  defp super_closure_binding(super_var, arity) do
    super_node = {super_var, [], nil}
    closure = {:&, [], [{:/, [], [{:super, [], nil}, arity]}]}
    {[super_node], [{:=, [], [super_node, closure]}]}
  end

  # Overlay each `\\ default` from `defaults` (position → expression) onto the dispatcher's
  # catch-all arg at that position. A `\\` may only appear in a `def`/`defp` head.
  defp with_defaults(args, defaults) when map_size(defaults) == 0, do: args

  defp with_defaults(args, defaults) do
    args
    |> Enum.with_index()
    |> Enum.map(fn {arg, pos} ->
      case Map.fetch(defaults, pos) do
        {:ok, default} -> {:\\, [], [arg, default]}
        :error -> arg
      end
    end)
  end

  # One lifted *mutant* clause: the candidate's single mutated source clause, renamed to
  # `<base>`, given the `mutare_active` extra arg, and gated `when mutare_active === <id> [and
  # <its own guard>]`. Raw body (no in-place selectors): only one mutant is ever active, so a
  # body selector here could never fire.
  defp lifted_mutant(%Group{} = group, id, clause, witness) do
    {clause_meta, call_meta, args, guards, body} = clause_parts(clause)
    guard = GuardBuild.and_into(GuardBuild.gate(id, group.var), GuardBuild.combine(guards))
    body = ImportWitness.prepend(body, witness)
    lifted_clause(group, clause_meta, call_meta, args, guard, body)
  end

  # One lifted clause for **several guard mutants** of one source clause: the source head
  # patterns, one copy of the raw body, and a `when` alternative per member, each gated on its
  # own id —
  #
  #     defp <base>(mutare_active, x)
  #          when mutare_active === 101 and x > 10
  #          when mutare_active === 102 and x >= 9 do
  #       <raw body, once>
  #     end
  #
  # Alternatives, not one boolean over the members: each `when` alternative is tried on its
  # own and a failing one — a raising one included — fails only itself, while `andalso`
  # short-circuits on the gate before an inactive member's guard is evaluated. So with member
  # `idᵢ` active the clause behaves exactly as `lifted_mutant/4`'s clause for `idᵢ` did, and
  # with none active it fails and dispatch continues. When the active member's guard fails,
  # the original below still excludes that id, so dispatch reaches the *next source clause*,
  # never the unmutated version — as it did with a clause per mutant.
  #
  # A member whose source guard is itself `when a when b` contributes two alternatives (the
  # gate distributed over both); `GuardBuild.sequence/1` flattens them into the one
  # right-nested sequence the compiler accepts. No helper function, body parameter, or
  # function boundary is introduced: this is not raw-body outlining (NOTES "Raw-body
  # outlining"), and the body's bindings and `__ENV__.function` are what they were.
  defp lifted_guard_group(
         %Group{} = group,
         plan,
         [{_id, {:guard, index, _}, witness} | _] = members
       ) do
    {clause_meta, call_meta, args, _guards, body} = clause_parts(Enum.at(plan.clauses, index))

    guard =
      members
      |> Enum.map(fn {id, {:guard, _index, guards}, _witness} ->
        GuardBuild.and_into(GuardBuild.gate(id, group.var), GuardBuild.combine(guards))
      end)
      |> GuardBuild.sequence()

    body = ImportWitness.prepend(body, witness)
    lifted_clause(group, clause_meta, call_meta, args, guard, body)
  end

  # One lifted *original* clause: the source clause (with its in-place body selectors), renamed
  # to `<base>`, given the `mutare_active` extra arg, and gated `when mutare_active !== <id>` for
  # each `id` that overrides/drops it — so it yields to its mutant clauses when their id is
  # active, and behaves normally otherwise (including for any skipped/poisoned id).
  defp lifted_original(%Group{} = group, clause, excluded_ids) do
    {clause_meta, call_meta, args, guards, body} = clause_parts(clause)

    guard =
      GuardBuild.merge(GuardBuild.exclusion(excluded_ids, group.var), GuardBuild.combine(guards))

    lifted_clause(group, clause_meta, call_meta, args, guard, body)
  end

  # Assemble a `<base>` clause: `defp <base>(mutare_active, [<super_var>,] <args...>) [when
  # <guard>], <body>`. The source clause's `meta` (its line) is preserved on the `defp` and the
  # head call — *not* reset to `[]` — so `Sourceror`'s line-assigning normalizer stays anchored
  # to the original source lines. Without it the body's `[]`-meta selector clauses (`<id> -> …`)
  # get stale lines, and a bare integer id then renders as a `:line`-but-no-`:token` literal that
  # crashes the Elixir formatter.
  #
  # When the group uses `super` (`super_var` non-`nil`), every base clause takes the forwarding
  # closure as its second parameter; this clause's body is rewritten to call `super` through it.
  # A clause whose own body has no `super` still takes the (shared) parameter but ignores it — a
  # bare `_` (`super_param/2`).
  defp lifted_clause(%Group{} = group, clause_meta, call_meta, args, guard, body) do
    {body, super_params} = super_param(body, group.super_var)
    call = {group.base, call_meta, [Recorder.catch_all_pattern(group.var) | super_params] ++ args}
    head = if guard, do: {:when, [], [call, guard]}, else: call
    {:defp, clause_meta, [head | body]}
  end

  # The super-closure parameter for one base clause, plus its rewritten body. `nil` (super-free
  # group) leaves both untouched. Otherwise the body's `super(...)` calls become `<super_var>.(...)`;
  # the clause takes the closure as a parameter, named `<super_var>` when it is used and a bare
  # `_` when this clause has no `super` (the parameter exists only to match the base's shared
  # arity). A bare `_` — not a salted `_<super_var>` — because the latter could *duplicate* a
  # source variable already in the head (a sibling clause head reusing `_mutare_super`): a
  # repeated underscored name warns *and* silently turns the head into an equality match, breaking
  # dispatch. `_` never binds, so it can neither collide nor constrain however many appear.
  defp super_param(body, nil), do: {body, []}

  defp super_param(body, super_var) do
    case Super.rewrite(body, super_var) do
      {body, true} -> {body, [{super_var, [], nil}]}
      {body, false} -> {body, [{:_, [], nil}]}
    end
  end

  # Deconstruct a function clause into `{clause_meta, head_call_meta, head_args, guards,
  # body_kw}`. A 0-arity head carries a `nil` arg context rather than a list, which becomes `[]`.
  # Default-argument annotations (`a \\ 1`) are stripped from the head args — the base function
  # takes the full arity (the dispatcher already resolved the defaults), and `\\` is legal only
  # in a public head anyway.
  defp clause_parts({_vis, clause_meta, [head | body]} = clause) do
    {_name, call_meta, args} = ClauseAST.head_call(head)
    args = if is_list(args), do: strip_arg_defaults(args), else: []
    {clause_meta, call_meta, args, ClauseAST.guards(clause), body}
  end

  defp strip_arg_defaults(args) do
    Enum.map(args, fn
      {:\\, _meta, [pattern, _default]} -> pattern
      arg -> arg
    end)
  end

  defp dispatcher_args(0), do: []
  defp dispatcher_args(arity), do: Enum.map(1..arity, &{:"mutare_arg#{&1}", [], nil})
end
