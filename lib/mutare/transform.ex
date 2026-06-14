defmodule Mutare.Transform do
  @moduledoc """
  Source → metamutant transform.

  Two mechanisms, chosen by where a mutation lands:

  ## In-place selector (body expressions)

  An operator inside a body is wrapped in a tail-position `case` reading the
  active mutant id from `:persistent_term`:

      # source:   total >= threshold
      case :persistent_term.get(:mutare_active, 0) do
        17 -> total > threshold     # mutant 17:  >= → >
        _  -> total >= threshold    # baseline + every other mutant
      end

  Substituting a node with a value-equivalent `case` preserves its position, so
  tail calls stay tail calls (LCO). Nested sites work because the catch-all holds
  the *transformed* children, reachable whenever an outer mutant is inactive.

  ## Function lifting + dispatcher (guards, dispatch)

  A `case` is illegal in a `when` guard, and guards drive dispatch *across*
  clauses, so guard mutations cannot be done in place. Instead the whole clause
  group is duplicated — once unchanged (`__orig`), once per mutation (`__mut`) —
  and a bare catch-all dispatcher forwards args to the active copy by id:

      def f(a) do
        case :persistent_term.get(:mutare_active, 0) do
          5 -> __mutare_f_1_m5(a)     # guard mutated in this copy
          _ -> __mutare_f_1_orig(a)
        end
      end
      defp __mutare_f_1_orig(a) when a >= 1, do: ...   # in-place applies here
      defp __mutare_f_1_m5(a) when a > 1, do: ...       # one guard changed

  In-place selectors live only in `__orig` (and in non-lifted code); the `__mut`
  copies reuse the original bodies — sound because exactly one mutant is ever
  active. The public `f/arity` is unchanged at the module boundary.

  Ranges are captured against the *original* AST, which is what the diff report
  patches against.
  """

  alias Mutare.Site

  @default_mutators [Mutare.Mutators.Arithmetic, Mutare.Mutators.Relational]

  # Threading context for a single transform pass. Two roles live here, kept
  # visibly apart: read-only config (`file`, `mutators`, `skip_ids`), set once;
  # and accumulators (`next_id`, `group`, `sites`), updated as ids are assigned
  # and sites recorded. A struct (not a bare map) makes the split explicit and a
  # stray field name fail loudly. The whole struct is threaded through every
  # stage — never destructured into loose values — so the shape stays uniform.
  defmodule Ctx do
    @moduledoc false

    @type t :: %__MODULE__{
            file: String.t(),
            mutators: [module()],
            skip_ids: MapSet.t(),
            next_id: pos_integer(),
            group: non_neg_integer(),
            sites: [Mutare.Site.t()]
          }

    defstruct [
      # config — read-only for the pass
      :file,
      :mutators,
      :skip_ids,
      # accumulators — threaded and updated
      next_id: 1,
      group: 0,
      sites: []
    ]
  end

  @doc """
  Transform a source string into `{metamutant_source, [%Site{}]}`.

  Options:

    * `:file` — path recorded on each site (default `"nofile"`)
    * `:mutators` — list of mutator modules (default arithmetic + relational)
    * `:start_id` — first mutant id to assign (default `1`)
  """
  @spec transform_string(String.t(), keyword()) :: {String.t(), [Site.t()]}
  def transform_string(source, opts \\ []) when is_binary(source) do
    ctx = %Ctx{
      file: Keyword.get(opts, :file, "nofile"),
      mutators: Keyword.get(opts, :mutators, @default_mutators),
      next_id: Keyword.get(opts, :start_id, 1),
      # Mutant ids to drop (e.g. compile-poisoning, found by the runner): their
      # site is still recorded (`poisoned: true`, for the denominator and id
      # stability) but no selector/copy is generated, so the metamutant compiles.
      skip_ids: Keyword.get(opts, :skip_ids, MapSet.new())
      # `group` and `sites` start at their struct defaults (0 / []).
    }

    {transformed, ctx} =
      source
      |> Sourceror.parse_string!()
      |> transform_node(ctx)

    metamutant =
      transformed
      |> normalize_keyword_blocks()
      |> Sourceror.to_string()

    ignore = ignore_lines(source)
    sites = Enum.map(Enum.reverse(ctx.sites), &%{&1 | ignored: &1.line in ignore})

    {metamutant, sites}
  end

  # Lines suppressed by a `# mutare:ignore` comment. A *trailing* comment
  # (`code # mutare:ignore`) suppresses its own line; a *standalone* comment
  # suppresses the next line. Text-scanned, so the (rare) literal string
  # `"# mutare:ignore"` would also match — acceptable for now.
  defp ignore_lines(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce(MapSet.new(), fn {text, lineno}, acc ->
      cond do
        Regex.match?(~r/^\s*#\s*mutare:ignore\b/, text) -> MapSet.put(acc, lineno + 1)
        Regex.match?(~r/#\s*mutare:ignore\b/, text) -> MapSet.put(acc, lineno)
        true -> acc
      end
    end)
  end

  # === module / statement structure =========================================

  # A module: transform the body of its do-block(s).
  defp transform_node({:defmodule, meta, [alias_node, do_keyword]}, ctx)
       when is_list(do_keyword) do
    {do_keyword, ctx} = transform_do_keyword(do_keyword, ctx)
    {{:defmodule, meta, [alias_node, do_keyword]}, ctx}
  end

  # A block: either a module body (contains clauses → group + lift) or an
  # ordinary sequence (recurse so nested modules are still reached).
  defp transform_node({:__block__, meta, statements}, ctx) do
    if Enum.any?(statements, &clause_signature/1) do
      {statements, ctx} = transform_statements(statements, ctx)
      {{:__block__, meta, statements}, ctx}
    else
      {statements, ctx} = Enum.map_reduce(statements, ctx, &transform_node/2)
      {{:__block__, meta, statements}, ctx}
    end
  end

  # Anything else is an expression: mutate operators in place.
  defp transform_node(node, ctx), do: in_place(node, ctx)

  defp transform_do_keyword(keyword, ctx) do
    Enum.map_reduce(keyword, ctx, fn
      {{:__block__, _, [:do]} = key, body}, ctx ->
        {body, ctx} = transform_body(body, ctx)
        {{key, body}, ctx}

      {:do, body}, ctx ->
        {body, ctx} = transform_body(body, ctx)
        {{:do, body}, ctx}

      entry, ctx ->
        {entry, ctx}
    end)
  end

  defp transform_body({:__block__, meta, statements}, ctx) do
    {statements, ctx} = transform_statements(statements, ctx)
    {{:__block__, meta, statements}, ctx}
  end

  defp transform_body(single, ctx) do
    case transform_statements([single], ctx) do
      {[one], ctx} -> {one, ctx}
      {many, ctx} -> {{:__block__, [], many}, ctx}
    end
  end

  defp transform_statements(statements, ctx) do
    statements
    |> chunk_clause_runs()
    |> Enum.flat_map_reduce(ctx, fn
      {:clauses, clauses}, ctx ->
        transform_clause_group(clauses, ctx)

      {:other, statement}, ctx ->
        {node, ctx} = transform_node(statement, ctx)
        {[node], ctx}
    end)
  end

  # Group maximal runs of consecutive clauses that share {visibility, name, arity}.
  defp chunk_clause_runs(statements) do
    statements
    |> Enum.reduce([], fn statement, acc ->
      case {clause_signature(statement), acc} do
        {nil, acc} ->
          [{:other, statement} | acc]

        {sig, [{:clauses, sig, clauses} | rest]} ->
          [{:clauses, sig, [statement | clauses]} | rest]

        {sig, acc} ->
          [{:clauses, sig, [statement]} | acc]
      end
    end)
    |> Enum.map(fn
      {:clauses, _sig, clauses} -> {:clauses, Enum.reverse(clauses)}
      other -> other
    end)
    |> Enum.reverse()
  end

  # === clause groups: lift, or mutate bodies in place ========================

  defp transform_clause_group(clauses, ctx) do
    {_vis, name, _arity} = clause_signature(hd(clauses))
    lifted_muts = lifted_mutations(clauses, ctx.mutators)

    if lifted_muts != [] and liftable?(name, clauses) do
      lift(clauses, lifted_muts, ctx)
    else
      Enum.flat_map_reduce(clauses, ctx, fn clause, ctx ->
        {clause, ctx} = in_place(clause, ctx)
        {[clause], ctx}
      end)
    end
  end

  # All lifted mutations for a clause group: guard operator swaps + clause drops.
  defp lifted_mutations(clauses, mutators) do
    guard_mutations(clauses, mutators) ++ clause_drop_mutations(clauses)
  end

  # Drop one clause of a multi-clause function. Inputs the dropped clause handled
  # now fall to a later clause (or raise FunctionClauseError) — killed if tested.
  defp clause_drop_mutations(clauses) when length(clauses) < 2, do: []

  defp clause_drop_mutations(clauses) do
    clauses
    |> Enum.with_index()
    |> Enum.map(fn {clause, index} ->
      %{type: :drop, clause_index: index, clause: clause, range: Sourceror.get_range(clause)}
    end)
  end

  defp lift(clauses, lifted_muts, ctx) do
    {vis, name, arity} = clause_signature(hd(clauses))
    group = ctx.group + 1
    ctx = %{ctx | group: group}
    base = base_name(name, arity, group)

    # The unchanged copy carries the in-place selectors (body mutations).
    {orig_clauses, ctx} =
      Enum.flat_map_reduce(clauses, ctx, fn clause, ctx ->
        {clause, ctx} = in_place(clause, ctx)
        {[clause], ctx}
      end)

    orig_defs = Enum.map(orig_clauses, &rename_clause(&1, :"#{base}_orig", :defp))

    # One private copy per lifted mutation (original bodies, one change applied).
    # A skipped (poisoned) id records its site but emits no copy/dispatcher clause.
    {mut_results, ctx} =
      Enum.flat_map_reduce(lifted_muts, ctx, fn mut, ctx ->
        id = ctx.next_id

        if id in ctx.skip_ids do
          ctx = %{
            ctx
            | next_id: id + 1,
              sites: [poison(lifted_site(id, mut, ctx.file)) | ctx.sites]
          }

          {[], ctx}
        else
          ctx = %{ctx | next_id: id + 1, sites: [lifted_site(id, mut, ctx.file) | ctx.sites]}

          defs =
            clauses
            |> apply_lifted_mutation(mut)
            |> Enum.map(&rename_clause(&1, :"#{base}_m#{id}", :defp))

          {[{id, defs}], ctx}
        end
      end)

    mut_ids = Enum.map(mut_results, &elem(&1, 0))
    mut_defs = Enum.flat_map(mut_results, &elem(&1, 1))
    dispatcher = build_dispatcher(vis, name, arity, mut_ids, base)

    {[dispatcher | orig_defs] ++ mut_defs, ctx}
  end

  # def f(mutare_arg1, ...) do
  #   case :persistent_term.get(:mutare_active, 0) do
  #     <id> -> <base>_m<id>(mutare_arg1, ...) ; _ -> <base>_orig(mutare_arg1, ...)
  #   end
  # end
  defp build_dispatcher(vis, name, arity, mut_ids, base) do
    args = dispatcher_args(arity)
    selector = Mutare.Metamutant.subject_ast()

    mut_clauses =
      Enum.map(mut_ids, fn id -> {:->, [], [[id], {:"#{base}_m#{id}", [], args}]} end)

    catch_all = {:->, [], [[{:_, [], nil}], {:"#{base}_orig", [], args}]}
    body = {:case, [], [selector, [do: mut_clauses ++ [catch_all]]]}

    {vis, [], [{name, [], args}, [do: body]]}
  end

  defp dispatcher_args(0), do: []
  defp dispatcher_args(arity), do: Enum.map(1..arity, &{:"mutare_arg#{&1}", [], nil})

  # Private base name for a lifted group. The trailing `g<group>` makes it unique
  # even across non-consecutive clause groups of the same name/arity; `?`/`!`
  # (valid only at the end of a function name) are replaced so they can sit mid-
  # identifier in `<base>_orig` / `<base>_m<id>`. The public dispatcher keeps the
  # real name (including any `?`/`!`).
  defp base_name(name, arity, group) do
    sanitized = name |> Atom.to_string() |> String.replace(["?", "!"], "_")
    "__mutare_#{sanitized}_#{arity}_g#{group}"
  end

  defp rename_clause({_vis, meta, [head | rest]}, new_name, new_vis) do
    {new_vis, meta, [rename_head(head, new_name) | rest]}
  end

  defp rename_head({:when, meta, [call | guards]}, new_name),
    do: {:when, meta, [rename_call(call, new_name) | guards]}

  defp rename_head(call, new_name), do: rename_call(call, new_name)

  defp rename_call({_name, meta, args}, new_name), do: {new_name, meta, args}

  # === guard mutations =======================================================

  # Every operator the mutators recognise, in every clause's guard. Delivered by
  # lifting (a guard can't host a `case`), but the mutation set is the same swap
  # logic the in-place mutators use — and operator swaps stay guard-safe.
  defp guard_mutations(clauses, mutators) do
    clauses
    |> Enum.with_index()
    |> Enum.flat_map(fn {clause, index} ->
      clause
      |> guards_of()
      |> Enum.flat_map(fn guard ->
        {_guard, muts} =
          Macro.postwalk(guard, [], fn node, acc ->
            extra =
              node
              |> mutations(mutators)
              |> Enum.map(fn {mutator, mutated} ->
                %{
                  type: :guard,
                  clause_index: index,
                  key: node_key(node),
                  original: node,
                  mutated: mutated,
                  mutator: mutator,
                  range: Sourceror.get_range(node)
                }
              end)

            {node, acc ++ extra}
          end)

        muts
      end)
    end)
  end

  defp guards_of({_vis, _meta, [{:when, _, [_call | guards]} | _rest]}), do: guards
  defp guards_of(_), do: []

  defp apply_lifted_mutation(clauses, %{type: :guard} = mut),
    do: apply_guard_mutation(clauses, mut)

  defp apply_lifted_mutation(clauses, %{type: :drop} = mut),
    do: List.delete_at(clauses, mut.clause_index)

  defp apply_guard_mutation(clauses, mut) do
    List.update_at(clauses, mut.clause_index, fn
      {vis, meta, [{:when, when_meta, [call | guards]} | rest]} ->
        guards = Enum.map(guards, &replace_node(&1, mut.key, mut.mutated))
        {vis, meta, [{:when, when_meta, [call | guards]} | rest]}
    end)
  end

  defp replace_node(ast, key, replacement) do
    Macro.prewalk(ast, fn node ->
      if node_key(node) == key, do: replacement, else: node
    end)
  end

  # Build the %Site{} for one lifted mutation. Transform owns the `mut` map's
  # shape and picks the constructor; Site owns the struct fields.
  defp lifted_site(id, %{type: :guard} = mut, file) do
    Site.lifted_guard(id, file, mut.range, mut.original, mut.mutated, mut.mutator)
  end

  defp lifted_site(id, %{type: :drop} = mut, file) do
    Site.clause_drop(id, file, mut.range, mut.clause)
  end

  # === clause signatures & liftability ======================================

  defp clause_signature({vis, _meta, [head | _rest]}) when vis in [:def, :defp] do
    case name_arity(head) do
      {name, arity} -> {vis, name, arity}
      :error -> nil
    end
  end

  defp clause_signature(_), do: nil

  defp name_arity({:when, _, [call | _guards]}), do: name_arity(call)
  defp name_arity({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp name_arity({name, _, context}) when is_atom(name) and is_atom(context), do: {name, 0}
  defp name_arity(_), do: :error

  # We can only lift functions whose name is a plain identifier (operator names
  # like `<>` can't be spelled as `__mutare_<>_2_orig(...)`) and which have no
  # default arguments (those expand to multiple arities; normalize-then-lift is
  # later work). Such groups fall back to in-place only.
  defp liftable?(name, clauses) do
    Regex.match?(~r/\A[a-z_][a-zA-Z0-9_]*[?!]?\z/, Atom.to_string(name)) and
      not Enum.any?(clauses, &default_args?/1)
  end

  defp default_args?({_vis, _meta, [head | _rest]}) do
    head |> head_args() |> Enum.any?(&match?({:\\, _, _}, &1))
  end

  defp head_args({:when, _, [call | _guards]}), do: head_args(call)
  defp head_args({_name, _, args}) when is_list(args), do: args
  defp head_args(_), do: []

  # === in-place transform (M1) ===============================================

  # Apply the in-place selector transform to one subtree, threading the ctx.
  defp in_place(node, ctx) do
    ranges =
      node
      |> capture_ranges(ctx.mutators)
      |> Map.drop(MapSet.to_list(unsafe_keys(node)))

    Macro.postwalk(node, ctx, fn current, ctx ->
      case Map.fetch(ranges, node_key(current)) do
        {:ok, %{range: range, node: original}} -> wrap_site(current, original, range, ctx)
        :error -> {current, ctx}
      end
    end)
  end

  defp wrap_site(node, original_node, range, ctx) do
    {clauses, ctx} =
      original_node
      |> mutations(ctx.mutators)
      |> Enum.reduce({[], ctx}, fn {mutator, mutated_node}, {clauses, ctx} ->
        id = ctx.next_id
        site = Site.in_place(id, ctx.file, range, original_node, mutated_node, mutator)
        ctx = %{ctx | next_id: id + 1}

        if id in ctx.skip_ids do
          # Poisoned: record the site, but emit no clause (so it can't poison).
          {clauses, %{ctx | sites: [poison(site) | ctx.sites]}}
        else
          clause = {:->, [], [[id], mutated_node]}
          {[clause | clauses], %{ctx | sites: [site | ctx.sites]}}
        end
      end)

    # All mutations here skipped → no selector; emit the node unchanged.
    case clauses do
      [] -> {node, ctx}
      _ -> {build_case(node, Enum.reverse(clauses)), ctx}
    end
  end

  defp poison(%Site{} = site), do: %{site | poisoned: true}

  # (case :persistent_term.get(:mutare_active, 0) do <id> -> <mutated> ; _ -> <default> end)
  #
  # Wrapped in a single-expression block so it renders safely in any position
  # (a bare `case` as a `key: value` value crashes Sourceror's formatter).
  defp build_case(default_node, mutant_clauses) do
    selector = Mutare.Metamutant.subject_ast()
    catch_all = {:->, [], [[{:_, [], nil}], default_node]}
    case_node = {:case, [], [selector, [do: mutant_clauses ++ [catch_all]]]}
    {:__block__, [], [case_node]}
  end

  # === shared helpers ========================================================

  # Sourceror represents a keyword-syntax key (`do:`, `else:`, but also `ms:`,
  # `env:`, any `key: value`) as `{:__block__, [format: :keyword], [key]}`. The
  # formatter crashes when such a pair's value becomes a `case`. We flip every
  # keyword-format key back to a plain atom key, which renders fine everywhere.
  # Metamutant only; the diff report patches the original source.
  defp normalize_keyword_blocks(ast) do
    Macro.prewalk(ast, fn
      {{:__block__, meta, [key]}, value} = pair when is_atom(key) and is_list(meta) ->
        if Keyword.get(meta, :format) == :keyword, do: {key, value}, else: pair

      other ->
        other
    end)
  end

  defp unsafe_keys(quoted) do
    MapSet.union(guard_keys(quoted), capture_arity_keys(quoted))
  end

  # Keys of operators inside `&fun/arity` captures, where `/` is an arity
  # separator (not division). We must not catch `& &1 / 2`, so we only match a
  # plain function reference over an integer literal.
  defp capture_arity_keys(quoted) do
    {_ast, keys} =
      Macro.prewalk(quoted, MapSet.new(), fn
        {:&, _meta, [{:/, _smeta, [left, right]} = slash]} = node, acc ->
          if function_ref?(left) and integer_literal?(right) do
            {node, add_key(acc, slash)}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    keys
  end

  defp function_ref?({name, _meta, context}) when is_atom(name) and is_atom(context), do: true
  defp function_ref?({{:., _, _}, _meta, args}) when is_list(args), do: true
  defp function_ref?(_), do: false

  defp integer_literal?(n) when is_integer(n), do: true
  defp integer_literal?({:__block__, _meta, [n]}) when is_integer(n), do: true
  defp integer_literal?(_), do: false

  defp add_key(set, node) do
    case node_key(node) do
      nil -> set
      key -> MapSet.put(set, key)
    end
  end

  # Keys of every node inside a `when` guard — in-place must not touch those
  # (a `case` is illegal in a guard); guard mutations are lifted instead.
  defp guard_keys(quoted) do
    {_ast, keys} =
      Macro.prewalk(quoted, MapSet.new(), fn
        {:when, _meta, [_head | guards]} = node, acc when guards != [] ->
          {node, Enum.reduce(guards, acc, &collect_keys/2)}

        node, acc ->
          {node, acc}
      end)

    keys
  end

  defp collect_keys(ast, acc) do
    {_ast, keys} =
      Macro.prewalk(ast, acc, fn node, inner ->
        case node_key(node) do
          nil -> {node, inner}
          key -> {node, MapSet.put(inner, key)}
        end
      end)

    keys
  end

  defp capture_ranges(quoted, mutators) do
    {_ast, ranges} =
      Macro.prewalk(quoted, %{}, fn node, acc ->
        if site?(node, mutators) do
          {node, Map.put(acc, node_key(node), %{range: Sourceror.get_range(node), node: node})}
        else
          {node, acc}
        end
      end)

    ranges
  end

  defp mutations(node, mutators) do
    Enum.flat_map(mutators, fn mutator ->
      case mutator.mutate(node) do
        :skip -> []
        nodes when is_list(nodes) -> Enum.map(nodes, &{mutator, &1})
      end
    end)
  end

  defp site?(node, mutators), do: mutations(node, mutators) != []

  defp node_key({_op, meta, _args}) when is_list(meta),
    do: {Keyword.get(meta, :line), Keyword.get(meta, :column)}

  defp node_key(_), do: nil
end
