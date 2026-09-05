defmodule Mutare.Transform.Analyze.QuoteEscape do
  @moduledoc false
  # The quote/unquote-escape fragment of the analyze walk, extracted from `Mutare.Transform.Analyze`.
  # A `quote` block is compile-time AST data, so its body is left raw — *except* the arguments of an
  # `unquote`/`unquote_splicing` that escape back to level 0, which are live runtime expressions and
  # are analyzed as such (`analyze_quote_args/4`, quote-level-aware). Escapes carry one extra hazard:
  # a match/`:binding_pattern` inside a live unquote argument may bind a variable the caller reads
  # after the quote is built, and an in-place selector on an ancestor of that binding would trap it
  # in a `case` branch — so `prune_quote_escape_*` strips exactly the candidates that would enclose
  # an escaping binding, bottom-up, while leaving siblings/descendants live. Re-enters the general
  # descent through the injected `descent` (`Mutare.Transform.Analyze`) at its one back-edge —
  # `analyze_quote_escape/3`'s `descent.annotate/2` — so this stays a one-way fragment of the walk.

  alias Mutare.AST
  alias Mutare.Transform.{Candidate, Meta}

  # Walk only a quote's block value(s), leaving quote options raw. The values of
  # `do:` entries are quoted data at `quote_level`; anything under an escaping
  # `unquote` that reaches level 0 is analyzed as ordinary runtime.
  def analyze_quote_args(descent, args, quote_level, mutators) do
    Enum.map(args, &analyze_quote_arg(descent, &1, quote_level, mutators))
  end

  defp analyze_quote_arg(descent, {:__block__, meta, [kw]}, quote_level, mutators)
       when is_list(kw) do
    {:__block__, meta, [analyze_quote_keyword(descent, kw, quote_level, mutators)]}
  end

  defp analyze_quote_arg(descent, kw, quote_level, mutators) when is_list(kw) do
    analyze_quote_keyword(descent, kw, quote_level, mutators)
  end

  defp analyze_quote_arg(_descent, other, _quote_level, _mutators), do: other

  defp analyze_quote_keyword(descent, kw, quote_level, mutators) do
    Enum.map(kw, fn
      {key, value} = pair ->
        if AST.key_atom(key) == :do,
          do: {key, analyze_quoted_data(descent, value, quote_level, mutators)},
          else: pair

      other ->
        other
    end)
  end

  # A nested `quote` adds one more quote level for its block body. If that quote
  # disables unquoting, its body is inert data from this analyzer's perspective.
  # Quote option values are different: they belong to the quote expression itself,
  # not the quoted block, so the prune pass below still scans them at the current
  # quote level for escaping bindings.
  defp analyze_quoted_data(descent, {:quote, meta, args} = node, quote_level, mutators)
       when is_list(args) do
    if quote_unquote_enabled?(args),
      do: {:quote, meta, analyze_quote_args(descent, args, quote_level + 1, mutators)},
      else: node
  end

  # `unquote` and `unquote_splicing` escape exactly one quote level. At level 1,
  # their argument is a live runtime expression; above that, the whole unquote is
  # still quoted data relative to the outer quote.
  #
  # A live unquote argument has one extra binding hazard compared with an ordinary
  # quoted expression: a match inside the argument may bind a variable the caller reads
  # after the quote is constructed (`quote(do: unquote((x = 1) + 2)); x`). A routed
  # `:binding_pattern` macro (for example `Kernel.destructure/2`) has the same
  # escaping-binding shape. An in-place selector on an ancestor of that binding would
  # wrap the binding in a `case` branch, and branch bindings do not leak, so even the
  # catch-all/baseline branch leaves the later read undefined. Keep mutating the live
  # argument, but prune only those candidates that would enclose the binding; descendants
  # and siblings that do not enclose it remain live.
  defp analyze_quoted_data(descent, {form, meta, [arg]}, 1, mutators)
       when form in [:unquote, :unquote_splicing],
       do: {form, meta, [analyze_quote_escape(descent, arg, mutators)]}

  defp analyze_quoted_data(_descent, {form, _meta, [_arg]} = node, quote_level, _mutators)
       when form in [:unquote, :unquote_splicing] and quote_level > 1,
       do: node

  defp analyze_quoted_data(descent, {form, meta, args}, quote_level, mutators) when is_list(args),
    do:
      {analyze_quoted_data(descent, form, quote_level, mutators), meta,
       Enum.map(args, &analyze_quoted_data(descent, &1, quote_level, mutators))}

  defp analyze_quoted_data(descent, {left, right}, quote_level, mutators),
    do:
      {analyze_quoted_data(descent, left, quote_level, mutators),
       analyze_quoted_data(descent, right, quote_level, mutators)}

  defp analyze_quoted_data(descent, list, quote_level, mutators) when is_list(list),
    do: Enum.map(list, &analyze_quoted_data(descent, &1, quote_level, mutators))

  defp analyze_quoted_data(_descent, other, _quote_level, _mutators), do: other

  defp analyze_quote_escape(descent, arg, mutators) do
    analyzed = descent.annotate(arg, mutators)
    {arg, _has_binding?} = prune_quote_escape_binding_ancestors(analyzed)
    arg
  end

  # Bottom-up over a live unquote argument: report whether a subtree contains an
  # escaping binding and strip unsafe ordinary Candidate.InPlace candidates from every
  # node whose selector would enclose that binding. The match node itself is
  # intentionally not stripped (the core
  # `=` node is not offered to mutators), and its RHS still mutates safely because the
  # outer match remains outside any selector. A routed `:binding_pattern` macro *is* a
  # call node that can carry whole-call candidates, so strip those too; without the
  # value-discarded tuple-export rewrite, an ordinary selector on the macro call would
  # trap the macro's escaping bindings exactly like an ancestor selector. Re-homed
  # tuple-export candidates already avoid that trap and stay live.
  defp prune_quote_escape_binding_ancestors({:=, meta, [lhs, rhs]}) do
    {lhs, _lhs_has?} = prune_quote_escape_binding_ancestors(lhs)
    {rhs, _rhs_has?} = prune_quote_escape_binding_ancestors(rhs)
    {{:=, meta, [lhs, rhs]}, true}
  end

  # A case subject is evaluated in the surrounding scope, so bindings there can
  # escape past the case. Clause bodies are branch-local; prune inside them, but do
  # not report their bindings to ancestors outside the case.
  defp prune_quote_escape_binding_ancestors({:case, meta, [subject, blocks]})
       when is_list(blocks) do
    {subject, subject_has?} = prune_quote_escape_binding_ancestors(subject)
    {blocks, _body_has?} = prune_quote_escape_binding_ancestors(blocks)
    node = {:case, meta, [subject, blocks]}
    node = if subject_has?, do: strip_quote_escape_inplace_candidates(node), else: node

    {node, subject_has?}
  end

  # If/unless condition bindings behave like surrounding-scope bindings, but
  # bindings made inside do/else bodies are branch-local. Keep the condition signal,
  # discard the body signal.
  defp prune_quote_escape_binding_ancestors({form, meta, [condition, body_kw]})
       when form in [:if, :unless] and is_list(body_kw) do
    {condition, condition_has?} = prune_quote_escape_binding_ancestors(condition)
    {body_kw, _body_has?} = prune_quote_escape_binding_ancestors(body_kw)
    node = {form, meta, [condition, body_kw]}
    node = if condition_has?, do: strip_quote_escape_inplace_candidates(node), else: node

    {node, condition_has?}
  end

  # Cond clause conditions and bodies share a clause-local scope, but nothing they
  # bind escapes beyond the cond construct. Prune internally, then stop propagation.
  defp prune_quote_escape_binding_ancestors({:cond, meta, [blocks]}) when is_list(blocks) do
    {blocks, _body_has?} = prune_quote_escape_binding_ancestors(blocks)
    {{:cond, meta, [blocks]}, false}
  end

  # Receive clause bodies and after clauses are local to the receive construct.
  # Prune internally without making unrelated outer candidates look unsafe.
  defp prune_quote_escape_binding_ancestors({:receive, meta, [blocks]}) when is_list(blocks) do
    {blocks, _body_has?} = prune_quote_escape_binding_ancestors(blocks)
    {{:receive, meta, [blocks]}, false}
  end

  # Bindings made inside these constructs do not escape to the unquote argument's
  # surrounding scope, so they cannot be the source of a post-quote undefined-variable
  # failure. Still prune inside their children: a selector inside the scoped body can
  # trap a binding that is read later in that same scoped body. Only the binding signal
  # is stopped at the construct boundary, so whole-construct candidates remain live.
  defp prune_quote_escape_binding_ancestors({form, _meta, args} = node)
       when form in [:fn, :for, :with, :try] and is_list(args),
       do: prune_quote_escape_scoped_construct(node)

  defp prune_quote_escape_binding_ancestors({:quote, meta, args}) when is_list(args) do
    {args, child_has?} = prune_quote_escape_live_quote_args(args, 1)
    node = {:quote, meta, args}
    node = if child_has?, do: strip_quote_escape_inplace_candidates(node), else: node

    {node, child_has?}
  end

  defp prune_quote_escape_binding_ancestors({form, meta, args}) when is_list(args) do
    {args, child_has?} = prune_quote_escape_binding_ancestors_each(args)
    node = {form, meta, args}
    binding_macro? = quote_escape_binding_pattern_macro?(meta)

    node =
      if child_has? or binding_macro?,
        do: strip_quote_escape_inplace_candidates(node),
        else: node

    {node, child_has? or binding_macro?}
  end

  defp prune_quote_escape_binding_ancestors({left, right}) do
    {left, left_has?} = prune_quote_escape_binding_ancestors(left)
    {right, right_has?} = prune_quote_escape_binding_ancestors(right)
    {{left, right}, left_has? or right_has?}
  end

  defp prune_quote_escape_binding_ancestors(list) when is_list(list),
    do: prune_quote_escape_binding_ancestors_each(list)

  defp prune_quote_escape_binding_ancestors(other), do: {other, false}

  defp prune_quote_escape_scoped_construct({form, meta, args}) when is_list(args) do
    {args, _child_has?} = prune_quote_escape_binding_ancestors_each(args)
    {{form, meta, args}, false}
  end

  defp prune_quote_escape_binding_ancestors_each(list) do
    {nodes, hass} = list |> Enum.map(&prune_quote_escape_binding_ancestors/1) |> Enum.unzip()
    {nodes, Enum.any?(hass)}
  end

  defp prune_quote_escape_live_quote_args(args, quote_level) do
    body_unquote_enabled? = quote_unquote_enabled?(args)

    args
    |> Enum.map(&prune_quote_escape_live_quote_arg(&1, quote_level, body_unquote_enabled?))
    |> Enum.unzip()
    |> then(fn {args, hass} -> {args, Enum.any?(hass)} end)
  end

  defp prune_quote_escape_live_quote_arg(
         {:__block__, meta, [kw]},
         quote_level,
         body_unquote_enabled?
       )
       when is_list(kw) do
    {kw, has?} = prune_quote_escape_live_quote_keyword(kw, quote_level, body_unquote_enabled?)
    {{:__block__, meta, [kw]}, has?}
  end

  defp prune_quote_escape_live_quote_arg(kw, quote_level, body_unquote_enabled?)
       when is_list(kw),
       do: prune_quote_escape_live_quote_keyword(kw, quote_level, body_unquote_enabled?)

  defp prune_quote_escape_live_quote_arg(other, _quote_level, _body_unquote_enabled?),
    do: {other, false}

  defp prune_quote_escape_live_quote_keyword(kw, quote_level, body_unquote_enabled?) do
    kw
    |> Enum.map(fn
      {key, value} = pair ->
        case AST.key_atom(key) do
          :do when body_unquote_enabled? ->
            {value, has?} = prune_quote_escape_quoted_data(value, quote_level)
            {{key, value}, has?}

          :do ->
            {pair, false}

          :bind_quoted ->
            {value, has?} = prune_quote_escape_binding_ancestors(value)
            {{key, value}, has?}

          _ ->
            {value, has?} = prune_quote_escape_binding_ancestors(value)
            {{key, value}, has?}
        end

      other ->
        {other, false}
    end)
    |> Enum.unzip()
    |> then(fn {kw, hass} -> {kw, Enum.any?(hass)} end)
  end

  defp prune_quote_escape_quote_args(args, quote_level, body_unquote_enabled?) do
    args
    |> Enum.map(&prune_quote_escape_quote_arg(&1, quote_level, body_unquote_enabled?))
    |> Enum.unzip()
    |> then(fn {args, hass} -> {args, Enum.any?(hass)} end)
  end

  defp prune_quote_escape_quote_arg({:__block__, meta, [kw]}, quote_level, body_unquote_enabled?)
       when is_list(kw) do
    {kw, has?} = prune_quote_escape_quote_keyword(kw, quote_level, body_unquote_enabled?)
    {{:__block__, meta, [kw]}, has?}
  end

  defp prune_quote_escape_quote_arg(kw, quote_level, body_unquote_enabled?) when is_list(kw),
    do: prune_quote_escape_quote_keyword(kw, quote_level, body_unquote_enabled?)

  defp prune_quote_escape_quote_arg(other, _quote_level, _body_unquote_enabled?),
    do: {other, false}

  defp prune_quote_escape_quote_keyword(kw, quote_level, body_unquote_enabled?) do
    kw
    |> Enum.map(fn
      {key, value} = pair ->
        case AST.key_atom(key) do
          :do when body_unquote_enabled? ->
            {value, has?} = prune_quote_escape_quoted_data(value, quote_level + 1)
            {{key, value}, has?}

          :do ->
            {pair, false}

          _option ->
            {value, has?} = prune_quote_escape_quoted_data(value, quote_level)
            {{key, value}, has?}
        end

      other ->
        {other, false}
    end)
    |> Enum.unzip()
    |> then(fn {kw, hass} -> {kw, Enum.any?(hass)} end)
  end

  defp prune_quote_escape_quoted_data({:quote, meta, args}, quote_level)
       when is_list(args) do
    {args, child_has?} =
      prune_quote_escape_quote_args(args, quote_level, quote_unquote_enabled?(args))

    node = {:quote, meta, args}
    node = if child_has?, do: strip_quote_escape_inplace_candidates(node), else: node

    {node, child_has?}
  end

  defp prune_quote_escape_quoted_data({form, meta, [arg]}, 1)
       when form in [:unquote, :unquote_splicing] do
    {arg, has?} = prune_quote_escape_binding_ancestors(arg)
    node = {form, meta, [arg]}
    node = if has?, do: strip_quote_escape_inplace_candidates(node), else: node

    {node, has?}
  end

  defp prune_quote_escape_quoted_data({form, _meta, [_arg]} = node, quote_level)
       when form in [:unquote, :unquote_splicing] and quote_level > 1,
       do: {node, false}

  defp prune_quote_escape_quoted_data({form, meta, args}, quote_level) when is_list(args) do
    {form, form_has?} = prune_quote_escape_quoted_data(form, quote_level)
    {args, args_has?} = prune_quote_escape_quoted_data_each(args, quote_level)
    {{form, meta, args}, form_has? or args_has?}
  end

  defp prune_quote_escape_quoted_data({left, right}, quote_level) do
    {left, left_has?} = prune_quote_escape_quoted_data(left, quote_level)
    {right, right_has?} = prune_quote_escape_quoted_data(right, quote_level)
    {{left, right}, left_has? or right_has?}
  end

  defp prune_quote_escape_quoted_data(list, quote_level) when is_list(list),
    do: prune_quote_escape_quoted_data_each(list, quote_level)

  defp prune_quote_escape_quoted_data(other, _quote_level), do: {other, false}

  defp prune_quote_escape_quoted_data_each(list, quote_level) do
    list
    |> Enum.map(&prune_quote_escape_quoted_data(&1, quote_level))
    |> Enum.unzip()
    |> then(fn {nodes, hass} -> {nodes, Enum.any?(hass)} end)
  end

  defp strip_quote_escape_inplace_candidates(node) do
    Candidate.update_candidates(node, fn candidates ->
      Enum.reject(candidates, &match?(%Candidate.InPlace{}, &1))
    end)
  end

  defp quote_escape_binding_pattern_macro?(meta) do
    binding_pattern_treatment?(Meta.piped_routing(meta)) or
      binding_pattern_treatment?(Meta.routing(meta))
  end

  defp binding_pattern_treatment?(:binding_pattern), do: true

  defp binding_pattern_treatment?(routing) when is_list(routing),
    do: Enum.any?(routing, &binding_pattern_treatment?/1)

  defp binding_pattern_treatment?({:keyword, treatments}) when is_list(treatments),
    do: binding_pattern_treatment?(treatments)

  defp binding_pattern_treatment?({:keyed, leading, pairs}),
    do:
      binding_pattern_treatment?(leading) or
        Enum.any?(pairs, fn {_key, position} -> binding_pattern_treatment?(position) end)

  defp binding_pattern_treatment?(_treatment), do: false

  @missing_quote_option :__mutare_missing_quote_option__

  def quote_unquote_enabled?(args) when is_list(args) do
    pairs = quote_keyword_pairs(args)

    case AST.opts_get(pairs, :unquote, @missing_quote_option) do
      @missing_quote_option ->
        AST.opts_get(pairs, :bind_quoted, @missing_quote_option) == @missing_quote_option

      value ->
        not literal_false?(value)
    end
  end

  defp quote_keyword_pairs(args) do
    Enum.flat_map(args, fn
      {:__block__, _meta, [kw]} when is_list(kw) ->
        Enum.filter(kw, &keyword_pair?/1)

      {_key, _value} = pair ->
        [pair]

      kw when is_list(kw) ->
        Enum.filter(kw, &keyword_pair?/1)

      _other ->
        []
    end)
  end

  defp keyword_pair?({_key, _value}), do: true
  defp keyword_pair?(_other), do: false

  defp literal_false?(false), do: true
  defp literal_false?({:__block__, _meta, [false]}), do: true
  defp literal_false?(_other), do: false
end
