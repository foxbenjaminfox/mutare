defmodule Mutare.Transform.LiftedEmit do
  @moduledoc false

  # The **AST-assembly half of lifting**: builds the public dispatcher and the gated base
  # clauses for a lifted function group, given the already-claimed candidate ids. Pure — no
  # `Ctx`, no id-claiming. `Mutare.Transform.emit_function_plan/2` owns the stateful half
  # (threading `Ctx`, claiming ids via `SelectorEmit.claim_items/4`, emitting in-place body
  # selectors) and calls `assemble/5` with plain data: the plan, the emitted source clauses, the
  # `{id, index, clause, witness}` claims, the group number, and the config.
  #
  # The interleaving scheme: each source clause's mutant clauses (one per candidate overriding
  # it, gated `when <var> === <id>`) precede the source clause itself (gated `when <var> !==
  # <those ids>`), so exactly one wins per `(id, args)` — the per-clause `C+M` lifting (see
  # `Mutare.Transform.FunctionPlan` and NOTES "lifting blowup").

  alias Mutare.Coverage.Recorder
  alias Mutare.Metamutant
  alias Mutare.Transform.{ClauseAST, Config, FunctionPlan, GuardBuild, ImportWitness, Super}

  # The fixed facts of one lifted group, derived once in `assemble/5` and read by every clause
  # builder below: the public signature (`vis`/`name`/`arity` — the dispatcher keeps the real
  # name), the private `base` name the clauses are relocated under, the dispatch variable `var`
  # (`Config.active_var`) and the file's runtime `namespace` (both for the active-id read and the
  # coverage record), and `super_var` — the super-forwarding closure variable, non-`nil` only
  # when a lifted body calls `super` (see `build_dispatcher/3`).
  defmodule Group do
    @moduledoc false
    @enforce_keys [:vis, :name, :arity, :base, :var, :namespace, :super_var]
    defstruct @enforce_keys
  end

  @typep claim :: {non_neg_integer(), non_neg_integer(), Macro.t() | :drop, term()}

  @doc """
  The lifted function group as emitted: the public dispatcher followed by the interleaved base
  clauses (`build_base_clauses/3`). `orig_clauses` are the source clauses with their in-place
  body selectors already emitted; `claimed` the `{id, clause_index, mutated_clause | :drop,
  witness}` claims; `group_number` the file-wide lifted-group counter (for a collision-free base
  name).
  """
  @spec assemble(FunctionPlan.t(), [Macro.t()], [claim()], non_neg_integer(), Config.t()) ::
          [Macro.t()]
  def assemble(
        %FunctionPlan{signature: {vis, name, arity}} = plan,
        orig_clauses,
        claimed,
        group_number,
        %Config{} = config
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
    mut_ids = Enum.map(claimed, fn {id, _index, _clause, _witness} -> id end)

    [
      build_dispatcher(group, mut_ids, defaults)
      | build_base_clauses(group, orig_clauses, claimed)
    ]
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
  defp build_base_clauses(%Group{} = group, orig_clauses, claimed) do
    # One grouping by source clause, not a scan of all M candidates per clause. Every claimed
    # candidate overrides (guard/literal/structure) or drops its clause, so the group *is* both
    # the clause's mutant clauses and the id set excluding its original version.
    by_clause = Enum.group_by(claimed, fn {_id, index, _clause, _witness} -> index end)

    orig_clauses
    |> Enum.with_index()
    |> Enum.flat_map(fn {orig, index} ->
      claims = Map.get(by_clause, index, [])

      mutant_clauses =
        for {id, _index, clause, witness} <- claims,
            clause != :drop,
            do: lifted_mutant(group, id, clause, witness)

      if ClauseAST.bodiless_header?(orig) do
        mutant_clauses
      else
        excluded = Enum.map(claims, fn {id, _index, _clause, _witness} -> id end)
        mutant_clauses ++ [lifted_original(group, orig, excluded)]
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
  defp build_dispatcher(%Group{} = group, mut_ids, defaults) do
    call_args = dispatcher_args(group.arity)
    head_args = with_defaults(call_args, defaults)
    var_node = Recorder.catch_all_pattern(group.var)
    read = active_read(group.var, group.namespace)

    {super_args, super_stmts} = super_closure_binding(group.super_var, group.arity)
    call = {group.base, [], [var_node | super_args] ++ call_args}

    record =
      if mut_ids == [], do: [], else: [Recorder.record_ast(mut_ids, group.var, group.namespace)]

    body = {:__block__, [], [read] ++ super_stmts ++ record ++ [call]}

    {group.vis, [], [{group.name, [], head_args}, [do: body]]}
  end

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
