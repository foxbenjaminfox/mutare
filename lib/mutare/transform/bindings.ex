defmodule Mutare.Transform.Bindings do
  @moduledoc false

  # The **scope** pre-pass: what a selector's export needs to know about the names around it.
  #
  # An in-place selector is a `case`, and a `case` branch traps what it binds; so a mutated
  # expression's bindings are re-exported through a tuple and rebound outside
  # (`Mutare.Transform.PipeEmit`). Which names a branch *can* export depends on the scope the
  # expression stands in, and no reading of the expression alone can say:
  #
  #   * a name **bound on entry** can be exported by every branch, whether it rebinds the name
  #     or not — a branch that does not names the incoming value, which is what the source
  #     leaves after a rebinding a mutant removed (`p = :before; count(xs, p = f)` → `count(xs)`
  #     leaves `p == :before`);
  #   * a name the expression binds **fresh** can be exported only by the branches that bind
  #     it. A mutant that drops such a binding is source-valid only where nothing **reads the
  #     name after** it: the binding then goes unexported, and the catch-all's copy stays
  #     trapped, unread. Where something does read it, the mutant's own source patch would not
  #     compile, so the mutant is withheld (`Mutare.Transform.Candidate.Delivery.gate/2`).
  #
  # So this pass stamps every binding-bearing node with `{bound, later}`: the names bound on
  # entry, and the names referenced after it. Each errs to one side only. `bound` may miss a
  # bound name (the node then takes the fresh rule, which is what every node took before this
  # pass), never claim an unbound one (an export naming it would not compile). `later` may
  # name a read that never happens (a mutant withheld for nothing), never miss one. The
  # default `Meta.bindings/1` answers for an unstamped node — a host's island, whose enclosing
  # scope core never sees — errs the same way: nothing bound, everything read.
  #
  # `bound` follows Elixir's scoping where it is plain and stays silent where it is not: a
  # definition's head patterns; a block's statements in order, each adding what
  # `Mutare.Transform.BindingEscapeEmit.expression_bindings/1` says escapes it, so an unrouted
  # call is a function here too; the clauses of `case`/`cond`/`fn`/`receive`/`try`/`with`/
  # `for`, each seeing its own patterns; and a `Kernel` `if`/`unless` condition. The siblings
  # of an argument list, a tuple, a list or an operator are **not** sequenced: Elixir resets
  # reads between them (`foo(x = 1, x)` does not compile) and lets their writes out only after
  # the whole expression, the last one winning. So a sibling sees the entry set *less* what
  # the siblings before it write — a name an earlier sibling rebinds is not one this position
  # may export as "incoming", since that write would override the sibling's. A routed macro's
  # value positions subtract every other position's writes, their order being the macro's. A
  # module body binds nothing for the definitions inside it. Nothing under a `quote`, a routed
  # foreign region, or a skipped call is stamped: nothing there is offered.
  #
  # `later` is every variable-shaped name in what follows the node in evaluation order — the
  # later siblings, then the enclosing node's, out to the body the node is in — with the match
  # forms (`=`, `<-`) read value first, since a pin in their pattern reads after the value. It
  # stops at the body of a definition, a `fn` or a structural form's clause, whose bindings
  # Elixir never lets out; inside one it applies no scoping, since a fresh name read outside
  # the scope that binds it is a source error, and counting it costs nothing.
  #
  # Runs after `Mutare.Transform.UnitReturns` (meta-only, so every earlier stamp survives) and
  # on a host's island as it is resolved (`Mutare.Transform.Analyze.Collect`), from a scope
  # that binds nothing and has everything after it.

  alias Mutare.AST
  alias Mutare.Transform.{BindingEscapeEmit, Calls, KeywordRouting, Meta, PatternStructure}

  @typedoc "Names bound on entry to a node, and names referenced after it (`:all` when unknown)."
  @type stamp :: {MapSet.t(atom()), MapSet.t(atom()) | :all}

  @definitions [:def, :defp, :defmacro, :defmacrop]
  @modules [:defmodule, :defimpl, :defprotocol]
  @structural [:case, :cond, :if, :unless, :with, :for, :try, :receive]
  @values [:expression, :interior, :lazy_expression]

  @doc """
  Stamp every binding-bearing node of `tree` with its `t:stamp/0` (`Meta.bindings/1`).

  `island?: true` walks a fragment whose surroundings are unknown: nothing bound on entry,
  everything read after.
  """
  @spec annotate(Macro.t(), keyword()) :: Macro.t()
  def annotate(tree, opts \\ []) do
    later = if Keyword.get(opts, :island?, false), do: :all, else: MapSet.new()
    {tree, _referenced, _binds?} = walk(tree, MapSet.new(), later)
    tree
  end

  @doc """
  Every name a match anywhere inside `node` binds — `=` and `<-` patterns at any depth,
  whatever scope they bind in. A superset of what escapes: a name here that is already bound
  on entry may be rebound by the node, and an export naming it costs at worst an identity.
  """
  @spec matched_names(Macro.t()) :: [atom()]
  def matched_names(node) do
    node
    |> Macro.prewalk([], fn
      {match, _meta, [pattern, _value]} = node, acc when match in [:=, :<-] ->
        {node, Enum.reverse(PatternStructure.bound_var_names(pattern)) ++ acc}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.uniq()
  end

  @doc "Every variable-shaped name anywhere inside `node` — a read, a binding, or a pattern."
  @spec referenced_names(Macro.t()) :: MapSet.t(atom())
  def referenced_names(node) do
    node
    |> Macro.prewalk(MapSet.new(), fn
      {name, _meta, context} = node, acc when is_atom(name) and is_atom(context) ->
        {node, MapSet.put(acc, name)}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  # --- the walk: `{node, names referenced inside, whether anything inside binds}` ------------

  defp walk({:quote, _meta, _args} = node, _bound, _later), do: opaque(node)

  defp walk({match, meta, [pattern, value]}, bound, later) when match in [:=, :<-] do
    pattern_names = referenced_names(pattern)
    {value, referenced, _binds?} = walk(value, bound, union(later, pattern_names))
    {{match, stamp(meta, bound, later), [pattern, value]}, union(referenced, pattern_names), true}
  end

  defp walk({:->, _meta, _args} = node, bound, later), do: clause(node, :bare, bound, later)

  defp walk({form, meta, args} = node, bound, later) when is_list(meta) and is_list(args) do
    cond do
      Meta.routing(meta) == :skip ->
        opaque(node)

      form in @modules and Calls.kernel_call?(node) ->
        module(node, later)

      form in @definitions and Calls.kernel_call?(node) ->
        definition(node, later)

      form == :fn or (form in @structural and Calls.kernel_call?(node)) ->
        structural(node, bound, later)

      true ->
        call(node, bound, later)
    end
  end

  # A variable, or a node whose head is one.
  defp walk({form, meta, context} = node, bound, later) when is_list(meta) do
    {form, referenced, binds?} = walk(form, bound, later)
    {{form, meta, context}, put_name(referenced, node), binds?}
  end

  defp walk({left, right}, bound, later) do
    {[left, right], referenced, binds?} = sequence([left, right], bound, later)
    {{left, right}, referenced, binds?}
  end

  defp walk(list, bound, later) when is_list(list), do: sequence(list, bound, later)

  defp walk(leaf, _bound, _later), do: {leaf, MapSet.new(), false}

  defp put_name(referenced, {name, _meta, context}) when is_atom(name) and is_atom(context),
    do: MapSet.put(referenced, name)

  defp put_name(referenced, _node), do: referenced

  # Not walked; still read for what it references and whether it binds.
  defp opaque(node), do: {node, referenced_names(node), matched_names(node) != []}

  # --- modules and definitions --------------------------------------------------------------

  # A module body binds nothing for what is defined inside it: its statements are walked from
  # an empty scope, and a module-level match adds nothing for the statements after it.
  defp module({form, meta, args}, later) do
    {lead, [last]} = Enum.split(args, -1)
    {last, referenced, binds?} = walk_unsequenced(last, later)
    {{form, meta, lead ++ [last]}, referenced, binds?}
  end

  defp walk_unsequenced([{key, {:__block__, meta, statements}} | rest], later)
       when is_list(statements) do
    {statements, referenced, binds?} = sequence(statements, MapSet.new(), later, false)
    {rest, rest_referenced, rest_binds?} = walk(rest, MapSet.new(), later)

    {[{key, {:__block__, meta, statements}} | rest], union(referenced, rest_referenced),
     binds? or rest_binds?}
  end

  defp walk_unsequenced(body, later), do: walk(body, MapSet.new(), later)

  # The head's patterns are bound throughout the body, whose `do`/`rescue`/`catch`/`else`/
  # `after` blocks scope as a `try`'s do. A default is evaluated in a generated clause.
  defp definition({form, meta, [head]}, _later) do
    {head, referenced, binds?} = head(head)
    {{form, meta, [head]}, referenced, binds?}
  end

  defp definition({form, meta, [head, body]}, _later) when is_list(body) do
    {head, head_referenced, head_binds?} = head(head)
    {body, referenced, binds?} = blocks(:try, body, head_names(head), MapSet.new())
    {{form, meta, [head, body]}, union(head_referenced, referenced), head_binds? or binds?}
  end

  defp definition(node, later), do: call(node, MapSet.new(), later)

  defp head({:when, meta, [call | guards]}) do
    {call, referenced, binds?} = head(call)
    {{:when, meta, [call | guards]}, union(referenced, referenced_names(guards)), binds?}
  end

  defp head({name, meta, params}) when is_list(params) do
    {params, referenced, binds?} =
      Enum.reduce(Enum.reverse(params), {[], MapSet.new(), false}, fn param,
                                                                      {acc, referenced, binds?} ->
        {param, param_referenced, param_binds?} = param(param)
        {[param | acc], union(referenced, param_referenced), binds? or param_binds?}
      end)

    {{name, meta, params}, referenced, binds?}
  end

  defp head(head), do: opaque(head)

  defp param({:\\, meta, [var, default]}) do
    {default, referenced, binds?} = walk(default, MapSet.new(), :all)
    {{:\\, meta, [var, default]}, union(referenced, referenced_names(var)), binds?}
  end

  defp param(param), do: opaque(param)

  defp head_names({:when, _meta, [call | _guards]}), do: head_names(call)

  defp head_names({_name, _meta, params}) when is_list(params),
    do: params |> Enum.flat_map(&param_names/1) |> MapSet.new()

  defp head_names(_head), do: MapSet.new()

  defp param_names({:\\, _meta, [var, _default]}), do: param_names(var)
  defp param_names(param), do: PatternStructure.bound_var_names(param)

  # --- structural forms: their clauses scope, and their heads sequence ---------------------

  defp structural({:fn, meta, clauses}, bound, later) do
    {clauses, referenced, binds?} = clauses(clauses, :pattern, bound, later)
    {{:fn, meta, clauses}, referenced, binds?}
  end

  # The subject (or condition) is evaluated first, and what it binds the clauses see.
  defp structural({form, meta, [subject, blocks]}, bound, later)
       when form in [:case, :if, :unless] and is_list(blocks) do
    {blocks, referenced, binds?} = blocks(form, blocks, union(bound, escaping(subject)), later)

    {subject, subject_referenced, subject_binds?} =
      walk(subject, bound, union(later, referenced))

    binds? = subject_binds? or binds?

    {{form, stamp_if(meta, binds?, bound, later), [subject, blocks]},
     union(subject_referenced, referenced), binds?}
  end

  defp structural({form, meta, [blocks]}, bound, later)
       when form in [:cond, :receive, :try] and is_list(blocks) do
    {blocks, referenced, binds?} = blocks(form, blocks, bound, later)
    {{form, stamp_if(meta, binds?, bound, later), [blocks]}, referenced, binds?}
  end

  # `with`/`for`: the clauses before the blocks bind in sequence for the blocks; a `for`'s
  # options (`into:`, `reduce:`, `uniq:`) ride in the same keyword list as its blocks.
  defp structural({form, meta, [_ | _] = args}, bound, later) when form in [:with, :for] do
    case Enum.split(args, -1) do
      {clauses, [blocks]} when is_list(blocks) ->
        {clauses, inner, clauses_referenced, clauses_binds?} =
          generators(clauses, bound, blocks)

        {blocks, referenced, binds?} = blocks(form, blocks, inner, later, bound)
        binds? = clauses_binds? or binds?

        {{form, stamp_if(meta, binds?, bound, later), clauses ++ [blocks]},
         union(clauses_referenced, referenced), binds?}

      _other ->
        call({form, meta, args}, bound, later)
    end
  end

  # A structural form in a shape this pass does not read is walked as a call.
  defp structural(node, bound, later), do: call(node, bound, later)

  # `pattern <- value` binds the pattern for what follows; any other clause is an expression
  # whose escaping bindings follow it, like a statement. Nothing outside the form reads either.
  defp generators(clauses, bound, blocks) do
    {clauses, inner, referenced, binds?} =
      clauses
      |> Enum.with_index()
      |> Enum.reduce({[], bound, MapSet.new(), false}, fn {clause, i},
                                                          {acc, bound, referenced, binds?} ->
        rest = Enum.drop(clauses, i + 1)

        {clause, clause_referenced, clause_binds?} =
          walk(clause, bound, referenced_names([rest, blocks]))

        {[clause | acc], union(bound, generator_names(clause)),
         union(referenced, clause_referenced), binds? or clause_binds?}
      end)

    {Enum.reverse(clauses), inner, referenced, binds?}
  end

  defp generator_names({:<-, _meta, [{:when, _when_meta, [pattern | _guards]}, _value]}),
    do: PatternStructure.bound_var_names(pattern)

  defp generator_names({:<-, _meta, [pattern, _value]}),
    do: PatternStructure.bound_var_names(pattern)

  defp generator_names(clause), do: escaping(clause)

  # The keyword blocks of a structural form (or of a definition, read as a `try`'s). A `->`
  # clause list is scoped per clause; a plain block is a statement sequence. An `else:` sees
  # `outer` — a `with`'s `else` never sees its clauses' bindings. What a block binds never
  # leaves the form, so nothing is read after it.
  defp blocks(form, blocks, bound, _later, outer \\ nil) do
    outer = outer || bound

    blocks
    |> Enum.reverse()
    |> Enum.reduce({[], MapSet.new(), false}, fn
      {key, value}, {acc, referenced, binds?} ->
        name = AST.key_atom(key)
        scope = if name == :else, do: outer, else: bound

        {value, value_referenced, value_binds?} =
          block(form, name, value, scope, MapSet.new())

        {[{key, value} | acc], union(referenced, value_referenced), binds? or value_binds?}

      other, {acc, referenced, binds?} ->
        {other, other_referenced, other_binds?} = opaque(other)
        {[other | acc], union(referenced, other_referenced), binds? or other_binds?}
    end)
  end

  defp block(form, key, [{:->, _, _} | _] = clauses, bound, later),
    do: clauses(clauses, heads_kind(form, key), bound, later)

  defp block(_form, _key, value, bound, later), do: scoped(value, bound, later)

  # A `cond` clause and a `receive`'s `after` are headed by an expression; every other clause
  # by patterns.
  defp heads_kind(:cond, _key), do: :expression
  defp heads_kind(:receive, :after), do: :expression
  defp heads_kind(_form, _key), do: :pattern

  defp clauses(clauses, kind, bound, later) do
    clauses
    |> Enum.reverse()
    |> Enum.reduce({[], MapSet.new(), false}, fn clause, {acc, referenced, binds?} ->
      {clause, clause_referenced, clause_binds?} = clause(clause, kind, bound, later)
      {[clause | acc], union(referenced, clause_referenced), binds? or clause_binds?}
    end)
  end

  # A clause's body sees its patterns, or what its head expression binds; what it binds is
  # read by nothing after it. (A bare `->`, outside any form this pass reads, keeps `later`.)
  defp clause({:->, meta, [heads, body]}, kind, bound, later) do
    names = clause_names(heads, kind)
    body_later = if kind == :bare, do: later, else: MapSet.new()
    {body, referenced, binds?} = scoped(body, union(bound, names), body_later)

    {heads, heads_referenced, heads_binds?} =
      clause_heads(heads, kind, bound, union(later, referenced))

    {{:->, meta, [heads, body]}, union(heads_referenced, referenced), heads_binds? or binds?}
  end

  defp clause(other, _kind, bound, later), do: walk(other, bound, later)

  defp clause_names([head], :expression), do: escaping(head)
  defp clause_names(heads, _kind), do: heads |> Enum.flat_map(&pattern_names/1) |> MapSet.new()

  defp clause_heads([head], :expression, bound, later) do
    {head, referenced, binds?} = walk(head, bound, later)
    {[head], referenced, binds?}
  end

  defp clause_heads(heads, _kind, _bound, _later),
    do: {heads, referenced_names(heads), matched_names(heads) != []}

  defp pattern_names({:when, _meta, args}) do
    {patterns, _guard} = Enum.split(args, -1)
    Enum.flat_map(patterns, &PatternStructure.bound_var_names/1)
  end

  defp pattern_names(pattern), do: PatternStructure.bound_var_names(pattern)

  # --- calls: siblings share the entry set, less what the ones before them write --------------

  defp call({form, meta, args}, bound, later) do
    {args, referenced, binds?} =
      case Meta.routing(meta) do
        routes when is_list(routes) -> routed_arguments(args, routes, bound, later)
        _unrouted -> sequence(args, bound, later, false)
      end

    # The callee expression runs first, so everything the arguments reference follows it.
    {form, form_referenced, form_binds?} = walk(form, bound, union(later, referenced))
    binds? = form_binds? or binds?

    {{form, stamp_if(meta, binds?, bound, later), args}, union(form_referenced, referenced),
     binds?}
  end

  # A route says how each position is read: only the value positions are walked. A macro
  # places its arguments as it likes, so each value position subtracts every other one's writes.
  defp routed_arguments(args, routes, bound, later) do
    positions = Enum.zip(args, routes)

    writes =
      for {arg, route} <- positions, route in @values, reduce: [] do
        acc -> [{arg, escaping(arg)} | acc]
      end

    positions
    |> Enum.reverse()
    |> Enum.reduce({[], MapSet.new(), false}, fn {arg, route}, {acc, referenced, binds?} ->
      others =
        for {other, names} <- writes,
            other != arg,
            reduce: MapSet.new(),
            do: (acc -> union(acc, names))

      {arg, arg_referenced, arg_binds?} =
        position(arg, route, MapSet.difference(bound, others), union(later, referenced))

      {[arg | acc], union(referenced, arg_referenced), binds? or arg_binds?}
    end)
  end

  defp position(arg, treatment, bound, later) when treatment in @values,
    do: walk(arg, bound, later)

  defp position(arg, {:keyword, _} = treatment, bound, later),
    do: keyword_position(arg, treatment, bound, later)

  defp position(arg, {:keyed, _, _} = treatment, bound, later),
    do: keyword_position(arg, treatment, bound, later)

  # A declared binding position (`destructure/2`'s pattern) binds, whatever its syntax.
  defp position(arg, :binding_pattern, _bound, _later),
    do: {arg, referenced_names(arg), PatternStructure.bound_var_names(arg) != []}

  defp position(arg, _treatment, _bound, _later), do: opaque(arg)

  defp keyword_position(arg, treatment, bound, later) do
    case KeywordRouting.decode(arg, treatment) do
      {:pairs, pairs, rewrap} ->
        writes =
          for {{_key, _key_treatment}, {value, value_treatment}} <- pairs,
              value_treatment in @values,
              reduce: MapSet.new() do
            acc -> union(acc, escaping(value))
          end

        {pairs, referenced, binds?} =
          pairs
          |> Enum.reverse()
          |> Enum.reduce({[], MapSet.new(), false}, fn {{key, key_treatment},
                                                        {value, value_treatment}},
                                                       {acc, referenced, binds?} ->
            # Its own writes are the node's to export; every other value's are not readable.
            own = if value_treatment in @values, do: escaping(value), else: MapSet.new()
            entry = MapSet.difference(bound, MapSet.difference(writes, own))

            {value, value_referenced, value_binds?} =
              position(value, value_treatment, entry, union(later, referenced))

            {key, key_referenced, key_binds?} =
              position(
                key,
                key_treatment,
                entry,
                union(later, union(referenced, value_referenced))
              )

            {[{key, value} | acc], referenced |> union(key_referenced) |> union(value_referenced),
             binds? or key_binds? or value_binds?}
          end)

        {rewrap.(pairs), referenced, binds?}

      {:whole, fallback} ->
        position(arg, fallback, bound, later)
    end
  end

  # --- sequences and scopes -------------------------------------------------------------------

  # A body: one statement, or a `__block__` of them, in order.
  defp scoped({:__block__, meta, statements}, bound, later) when is_list(statements) do
    {statements, referenced, binds?} = sequence(statements, bound, later)
    {{:__block__, stamp_if(meta, binds?, bound, later), statements}, referenced, binds?}
  end

  defp scoped(body, bound, later), do: walk(body, bound, later)

  # Items evaluated in order, each followed by what the ones after it reference. Statements
  # (`sequenced?`) see what the ones before them bind; siblings of an expression see the entry
  # set less what the ones before them write — a write only the expression's end lets out.
  defp sequence(items, bound, later, sequenced? \\ true) do
    writes = Enum.map(items, &escaping/1)

    entries =
      writes
      |> Enum.scan(bound, fn names, entry ->
        if sequenced?, do: union(entry, names), else: MapSet.difference(entry, names)
      end)

    items
    |> Enum.zip([bound | entries])
    |> Enum.reverse()
    |> Enum.reduce({[], MapSet.new(), false}, fn {item, entry}, {acc, referenced, binds?} ->
      {item, item_referenced, item_binds?} = walk(item, entry, union(later, referenced))
      {[item | acc], union(referenced, item_referenced), binds? or item_binds?}
    end)
  end

  defp escaping(node), do: node |> BindingEscapeEmit.expression_bindings() |> MapSet.new()

  defp union(:all, _names), do: :all
  defp union(_names, :all), do: :all
  defp union(left, right) when is_list(right), do: MapSet.union(left, MapSet.new(right))
  defp union(left, right), do: MapSet.union(left, right)

  defp stamp_if(meta, true, bound, later), do: stamp(meta, bound, later)
  defp stamp_if(meta, false, _bound, _later), do: meta

  defp stamp(meta, bound, later), do: Meta.put_bindings(meta, {bound, later})
end
