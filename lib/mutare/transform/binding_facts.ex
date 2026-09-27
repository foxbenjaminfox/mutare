defmodule Mutare.Transform.BindingFacts do
  @moduledoc false

  # Read an expression's binding facts without annotating it or building emitted code.
  # The scope pre-pass (`Bindings`), candidate analysis and delivery all use these readers:
  #
  #   * `expression_bindings/1` / `argument_bindings/2` — names guaranteed to escape,
  #     in binding order; may under-count, never claim a binding that does not escape.
  #   * `matched_names/1` — possible writes, including those in uncertain or local scopes;
  #     may over-count, never miss a possible binding the guaranteed reader cannot see.
  #   * `unknown_routing?/1` — whether a withheld classifier leaves an evaluated call's
  #     binding effect unknown.
  #   * `referenced_names/1` — all variable-shaped names, an over-approximation of reads.
  #
  # The guaranteed and possible readers deliberately keep separate walks: a lazy or syntax
  # position can contain a possible write without guaranteeing any escaping binding. They
  # share the resolution, keyword and quote decoders, not their descent policies. `Bindings`
  # owns the surrounding scope; none of these expression-local facts decides an export alone.

  alias Mutare.Transform.{KeywordRouting, PatternStructure, QuoteStructure, Resolve}

  @conditionals [:if, :unless, :and, :or, :&&, :||]

  @doc "Bindings guaranteed to escape an expression, each once, in the order they are bound (a match's right-hand side before its pattern)."
  @spec expression_bindings(Macro.t()) :: [atom()]
  def expression_bindings(node), do: node |> bound_names(%{}) |> Enum.uniq()

  defp bound_names({_form, meta, _args} = node, context) when is_list(meta),
    do: collect_bindings(node, Resolve.context(node, context))

  defp bound_names(node, context), do: collect_bindings(node, context)

  defp collect_bindings({:__block__, _, statements}, context) when is_list(statements) do
    {bindings, _context} =
      Enum.map_reduce(statements, context, fn statement, context ->
        {bound_names(statement, context), Resolve.advance_context(statement, context)}
      end)

    List.flatten(bindings)
  end

  # A withheld stage still receives argument zero when Kernel expands it. Inspect
  # that complete call so a conditional's branches never become its condition.
  defp collect_bindings({:|>, _meta, args} = pipe, context) do
    case Resolve.preserved_pipe_call(pipe, context) do
      nil -> argument_bindings(args, Resolve.effective_routing(pipe, context), context)
      call -> bound_names(call, context)
    end
  end

  # Only unconditional expression positions export bindings. Clause bodies, short-circuit
  # right operands, and syntax-routed arguments have their own scopes or evaluation rules.
  defp collect_bindings({:=, _, [pattern, rhs]}, context),
    do: bound_names(rhs, context) ++ PatternStructure.bound_var_names(pattern)

  defp collect_bindings({:case, _, [first | _]}, context), do: bound_names(first, context)

  defp collect_bindings({form, _, _}, _context)
       when form in [:fn, :for, :with, :try, :cond, :receive, :->, :&],
       do: []

  # Live quote parts execute in the surrounding scope: option values, and the arguments
  # of escapes in a quoted body (`QuoteStructure`).
  defp collect_bindings({:quote, _, args}, context) when is_list(args) do
    {parts, _rebuild} = QuoteStructure.parts(args)

    Enum.flat_map(parts, fn
      {value, :live} -> bound_names(value, context)
      {value, :quoted} -> unquote_bindings(value, context)
      {_value, :inert} -> []
    end)
  end

  # A Kernel conditional or short-circuit operator binds only through its condition (its
  # first operand); its branches are scopes of their own. Which calls those are is the
  # *identity*, whatever the spelling — `if`, `Kernel.if`, `K.if` — read from the stamp or,
  # unstamped inside a skipped call's argument, through the retained environment (a displaced
  # `if/2` there is the call its route describes, not a conditional).
  defp collect_bindings({form, _meta, args} = node, context) when is_list(args) do
    case {Resolve.kernel_form(node, context), args} do
      {name, [first | _]} when name in @conditionals ->
        bound_names(first, context)

      _call ->
        bound_names(form, context) ++
          argument_bindings(args, Resolve.effective_routing(node, context), context)
    end
  end

  defp collect_bindings({left, right}, context),
    do: bound_names(left, context) ++ bound_names(right, context)

  defp collect_bindings(list, context) when is_list(list),
    do: Enum.flat_map(list, &bound_names(&1, context))

  defp collect_bindings(_, _context), do: []

  defp argument_bindings(args, routing, context) do
    case routing do
      nil ->
        Enum.flat_map(args, &bound_names(&1, context))

      :skip ->
        # Skip withholds mutation and nested routing, not ordinary evaluation. A skipped call
        # that displaced no declaration still exports its arguments' bindings; one that did
        # reads by that declaration (`Resolve.effective_routing/2`) and never reaches here.
        Enum.flat_map(args, &bound_names(&1, context))

      treatments when is_list(treatments) and length(treatments) == length(args) ->
        Enum.zip(args, treatments)
        |> Enum.flat_map(fn {arg, treatment} ->
          argument_bindings_for(arg, treatment, context)
        end)

      # A stamp that does not fit the arguments. A rebuilt call is routed again before a
      # reader meets it (`Resolve.reroute/1`), so this is a static route whose fixed positions
      # a rebuilt call at another arity does not match — the written form would not have
      # routed. The stamp says nothing about this call; only a mutant branch reads this way,
      # and reading nothing there errs toward withholding the mutant.
      treatments when is_list(treatments) ->
        []

      # A classifier not invoked in a skipped region: its positions may bind, and nothing is
      # guaranteed. `unknown_routing?/1` reports the call to the gate, and
      # `matched_names/1` counts every name its arguments mention as a possible write.
      :unknown ->
        []
    end
  end

  @doc """
  The bindings guaranteed to escape one argument of a routed call, read as its `treatment`
  says: an `:expression`/`:interior` value's, a `:binding_pattern`'s pattern names, a keyword
  treatment's pairs by their own treatments, and nothing from a position read as syntax or
  evaluated at the callee's discretion.
  """
  @spec argument_bindings(Macro.t(), term()) :: [atom()]
  def argument_bindings(arg, treatment),
    do: arg |> argument_bindings_for(treatment, %{}) |> Enum.uniq()

  defp argument_bindings_for(arg, treatment, context) when treatment in [:expression, :interior],
    do: bound_names(arg, context)

  defp argument_bindings_for(arg, :binding_pattern, _context),
    do: PatternStructure.bound_var_names(arg)

  defp argument_bindings_for(arg, {:keyed, _, _} = treatment, context),
    do: keyword_bindings(arg, treatment, context)

  defp argument_bindings_for(arg, {:keyword, _} = treatment, context),
    do: keyword_bindings(arg, treatment, context)

  defp argument_bindings_for(_arg, _treatment, _context), do: []

  defp keyword_bindings(arg, treatment, context) do
    case KeywordRouting.decode(arg, treatment) do
      {:pairs, pairs, _rewrap} ->
        Enum.flat_map(pairs, fn {{key, key_treatment}, {value, value_treatment}} ->
          argument_bindings_for(key, key_treatment, context) ++
            argument_bindings_for(value, value_treatment, context)
        end)

      {:whole, fallback} ->
        argument_bindings_for(arg, fallback, context)
    end
  end

  defp unquote_bindings({form, _, args} = node, context) when is_list(args) do
    case QuoteStructure.quoted(node) do
      {:escape, arg, _rebuild} ->
        bound_names(arg, context)

      {:options, options, _rebuild} ->
        unquote_bindings(options, context)

      :inert ->
        []

      :data ->
        unquote_bindings(form, context) ++ Enum.flat_map(args, &unquote_bindings(&1, context))
    end
  end

  defp unquote_bindings({left, right}, context),
    do: unquote_bindings(left, context) ++ unquote_bindings(right, context)

  defp unquote_bindings(list, context) when is_list(list),
    do: Enum.flat_map(list, &unquote_bindings(&1, context))

  defp unquote_bindings(_, _context), do: []

  @doc """
  Every name a match anywhere inside `node` may bind — `=` and `<-` patterns, and the
  positions a route declares binding (`destructure/2`'s `:binding_pattern`, keyed refinements
  included) — at any depth, whatever scope or treatment encloses them. A superset of what is
  guaranteed to escape: a name here that is already bound on entry may be rebound by the
  node, and an export naming it costs at worst an identity; and it is what a sibling *may*
  write, which a conflict must count even where the write's execution is not certain.

  Inside a skipped call's arguments, which Resolve did not walk, a call's route is read
  through the environment the skipped call retains (`Resolve.preserved_routing/2`), as
  `expression_bindings/1` reads it: skip withholds mutation, not evaluation.
  A route there that is a classifier cannot be read; every name the call's arguments mention
  is then in this list, since a declared position binds nothing its syntax does not name, and
  `unknown_routing?/1` says the list bounds what the call binds rather than reading it.

  Inside a position a route reads as **syntax** (`:raw`, `:hosted`, a keyword value under
  either), which Resolve did not walk either, a nested call is that syntax too: a static
  route it resolves to still names its binding positions, and one that cannot be read
  contributes every name its arguments mention — but no call there is *unknown*. The
  enclosing route declared the region syntax, and the guaranteed reader
  (`expression_bindings/1`) vouches for nothing in it; a classifier nested there opens no hole a
  blanket would close.
  """
  @spec matched_names(Macro.t()) :: [atom()]
  def matched_names(node) do
    for {:bound, name} <- matched(node, %{}), uniq: true, do: name
  end

  @doc """
  Whether `node` contains a call whose binding effect cannot be read: one inside a skipped
  call's argument whose route is a `:routing` classifier, which is never invoked in a region
  it was withheld from (`Resolve.preserved_routing/2`). Such a call may bind names neither
  reader reports, so a delivery that must export what `node` binds withholds instead
  (`Candidate.Delivery.gate/2`); a call is read as ordinary only where no route is declared.
  A classifier nested in a syntax region is not unknown (`matched_names/1`): the region's
  route already says nothing in it is guaranteed to bind.
  """
  @spec unknown_routing?(Macro.t()) :: boolean()
  def unknown_routing?(node), do: :unknown in matched(node, %{})

  # The walk collects binding facts: `{:bound, name}` for a possible write, `:unknown` for a
  # call whose declared positions could not be obtained.
  defp matched({:__block__, _meta, statements}, context) when is_list(statements) do
    {names, _context} =
      Enum.map_reduce(statements, context, fn statement, context ->
        {matched(statement, context), Resolve.advance_context(statement, context)}
      end)

    List.flatten(names)
  end

  defp matched({match, _meta, [pattern, value]}, context) when match in [:=, :<-] do
    bound(PatternStructure.bound_var_names(pattern)) ++
      matched(pattern, context) ++ matched(value, context)
  end

  # A surviving pipe is a withheld Kernel stage, read as the call it denotes, or an operator.
  defp matched({:|>, _meta, _args} = pipe, context) do
    context = Resolve.context(pipe, context)

    case Resolve.preserved_pipe_call(pipe, context) do
      nil -> matched_call(pipe, context)
      call -> matched(call, context)
    end
  end

  defp matched({_form, meta, args} = node, context) when is_list(meta) and is_list(args),
    do: matched_call(node, Resolve.context(node, context))

  defp matched({form, meta, _context}, context) when is_list(meta), do: matched(form, context)

  defp matched({left, right}, context), do: matched(left, context) ++ matched(right, context)

  defp matched(list, context) when is_list(list), do: Enum.flat_map(list, &matched(&1, context))

  defp matched(_leaf, _context), do: []

  # The route is what the arguments mean (`Resolve.effective_routing/2`): a stamp, a
  # configured skip's displaced declaration, or the static route a call inside a skipped
  # argument resolves to — `:unknown` where it is a classifier this reader cannot invoke.
  # The arguments are then descended as the route reads them: a position it declares
  # syntax is descended as syntax.
  defp matched_call({form, _meta, args} = node, context) do
    routing = Resolve.effective_routing(node, context)

    declared_names(args, routing, context) ++
      matched(form, context) ++ matched_arguments(args, routing, context)
  end

  # The names a call's route declares its positions bind.
  defp declared_names(args, routes, _context) when is_list(routes) do
    args
    |> Enum.zip(routes)
    |> Enum.flat_map(fn {arg, treatment} -> declared_position_names(arg, treatment) end)
  end

  # A route this reader cannot obtain may declare any position binding: every name the
  # arguments mention is a possible write. In an evaluated region the call's effect is
  # unknown besides; in a syntax region it is the region's, which vouches for nothing.
  defp declared_names(args, :unknown, context) do
    names = bound(MapSet.to_list(referenced_names(args)))
    if syntax?(context), do: names, else: [:unknown | names]
  end

  defp declared_names(_args, _routing, _context), do: []

  # A stamped or declared route fits its call by construction (`Resolve.Arguments` checks
  # a keyword route where it is stamped). The readers only ever meet a source node here.
  defp matched_arguments(args, routes, context)
       when is_list(routes) and length(routes) == length(args) do
    args
    |> Enum.zip(routes)
    |> Enum.flat_map(fn {arg, treatment} -> matched_position(arg, treatment, context) end)
  end

  defp matched_arguments(args, _routing, context), do: matched(args, context)

  defp matched_position(arg, treatment, context) do
    cond do
      syntax_treatment?(treatment) -> matched(arg, syntax(context))
      keyword_treatment?(treatment) -> matched_keyword(arg, treatment, context)
      true -> matched(arg, context)
    end
  end

  defp matched_keyword(arg, treatment, context) do
    case KeywordRouting.decode(arg, treatment) do
      {:pairs, pairs, _rewrap} ->
        Enum.flat_map(pairs, fn {{key, key_treatment}, {value, value_treatment}} ->
          matched_position(key, key_treatment, context) ++
            matched_position(value, value_treatment, context)
        end)

      {:whole, fallback} ->
        matched_position(arg, fallback, context)
    end
  end

  # The treatments Resolve does not walk into (`Resolve.Arguments`): the region is the
  # macro's syntax, in the stamped form (`{:hosted, hosts}`) or the declared one.
  defp syntax_treatment?(:raw), do: true
  defp syntax_treatment?(:hosted), do: true
  defp syntax_treatment?({:hosted, _hosts}), do: true
  defp syntax_treatment?(_treatment), do: false

  defp keyword_treatment?({:keyword, _treatments}), do: true
  defp keyword_treatment?({:keyed, _leading, _refinements}), do: true
  defp keyword_treatment?(_treatment), do: false

  # The reading context inside a syntax region: what is nested there is syntax all the way
  # down — a nested call's own value positions were never resolved either.
  defp syntax(context), do: Map.put(context, :syntax?, true)
  defp syntax?(context), do: Map.get(context, :syntax?, false)

  defp bound(names), do: Enum.map(names, &{:bound, &1})

  defp declared_position_names(arg, :binding_pattern),
    do: bound(PatternStructure.bound_var_names(arg))

  defp declared_position_names(arg, {:keyword, _} = treatment),
    do: declared_keyword_names(arg, treatment)

  defp declared_position_names(arg, {:keyed, _, _} = treatment),
    do: declared_keyword_names(arg, treatment)

  defp declared_position_names(_arg, _treatment), do: []

  defp declared_keyword_names(arg, treatment) do
    case KeywordRouting.decode(arg, treatment) do
      {:pairs, pairs, _rewrap} ->
        Enum.flat_map(pairs, fn {{key, key_treatment}, {value, value_treatment}} ->
          declared_position_names(key, key_treatment) ++
            declared_position_names(value, value_treatment)
        end)

      {:whole, fallback} ->
        declared_position_names(arg, fallback)
    end
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
end
