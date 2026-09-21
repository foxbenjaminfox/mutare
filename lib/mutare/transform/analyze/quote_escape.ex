defmodule Mutare.Transform.Analyze.QuoteEscape do
  @moduledoc false
  # The quote/unquote-escape fragment of the analyze walk, extracted from `Mutare.Transform.Analyze`.
  # A `quote` block is compile-time AST data, so its body is left raw — *except* the arguments of an
  # `unquote`/`unquote_splicing` that escape back to level 0, which are live runtime expressions and
  # are analyzed as such (`analyze_quote_args/3`, quote-level-aware). Escapes carry one extra hazard:
  # a match/`:binding_pattern` inside a live unquote argument may bind a variable the caller reads
  # after the quote is built, and an in-place selector on an ancestor of that binding would trap it
  # in a `case` branch — so `prune_quote_escape_*` strips exactly the candidates that would enclose
  # an escaping binding, bottom-up, while leaving siblings/descendants live. Re-enters the general
  # descent at one point: `analyze_quote_escape/2`'s `Analyze.annotate/2`.

  alias Mutare.Transform.Analyze
  alias Mutare.Transform.{Candidate, Meta, QuoteStructure}

  # Analyze only a quote's `:quoted` body. A `:live` option value is left raw here: it runs,
  # but this pass offers no mutants in it (the prune pass below still reads its bindings).
  def analyze_quote_args(args, env) do
    {parts, rebuild} = QuoteStructure.parts(args)

    parts
    |> Enum.map(fn
      {value, :quoted} -> analyze_quoted_data(value, env)
      {value, _live_or_inert} -> value
    end)
    |> rebuild.()
  end

  # An escape's argument is a live runtime expression; a nested quote is inert as a whole
  # (`QuoteStructure`).
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
  defp analyze_quoted_data({form, meta, args} = node, env) when is_list(args) do
    case QuoteStructure.quoted(node) do
      # A `:skip`-routed unquote (`{Kernel.SpecialForms, :unquote, :skip}`) is an inert leaf: the
      # escaping argument stays as written. (The dispatcher never sees an unquote — quoted data is
      # walked here, not by `analyze/3` — so the stamp is read at this entry.)
      {:escape, arg, rebuild} ->
        if Meta.skipped?(node), do: node, else: rebuild.(analyze_quote_escape(arg, env))

      {:options, options, rebuild} ->
        rebuild.(analyze_quoted_data(options, env))

      :inert ->
        node

      :data ->
        {analyze_quoted_data(form, env), meta, Enum.map(args, &analyze_quoted_data(&1, env))}
    end
  end

  defp analyze_quoted_data({left, right}, env),
    do: {analyze_quoted_data(left, env), analyze_quoted_data(right, env)}

  defp analyze_quoted_data(list, env) when is_list(list),
    do: Enum.map(list, &analyze_quoted_data(&1, env))

  defp analyze_quoted_data(other, _env), do: other

  defp analyze_quote_escape(arg, env) do
    analyzed = Analyze.annotate(arg, env)
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
    {parts, rebuild} = QuoteStructure.parts(args)

    {values, hass} =
      parts
      |> Enum.map(fn
        {value, :live} -> prune_quote_escape_binding_ancestors(value)
        {value, :quoted} -> prune_quote_escape_quoted_data(value)
        {value, :inert} -> {value, false}
      end)
      |> Enum.unzip()

    child_has? = Enum.any?(hass)
    node = {:quote, meta, rebuild.(values)}
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

  defp prune_quote_escape_quoted_data({form, meta, args} = node) when is_list(args) do
    case QuoteStructure.quoted(node) do
      {:escape, arg, rebuild} ->
        {arg, has?} = prune_quote_escape_binding_ancestors(arg)
        node = rebuild.(arg)
        {if(has?, do: strip_quote_escape_inplace_candidates(node), else: node), has?}

      {:options, options, rebuild} ->
        {options, has?} = prune_quote_escape_quoted_data(options)
        node = rebuild.(options)
        {if(has?, do: strip_quote_escape_inplace_candidates(node), else: node), has?}

      :inert ->
        {node, false}

      :data ->
        {form, form_has?} = prune_quote_escape_quoted_data(form)
        {args, args_has?} = prune_quote_escape_quoted_data_each(args)
        {{form, meta, args}, form_has? or args_has?}
    end
  end

  defp prune_quote_escape_quoted_data({left, right}) do
    {left, left_has?} = prune_quote_escape_quoted_data(left)
    {right, right_has?} = prune_quote_escape_quoted_data(right)
    {{left, right}, left_has? or right_has?}
  end

  defp prune_quote_escape_quoted_data(list) when is_list(list),
    do: prune_quote_escape_quoted_data_each(list)

  defp prune_quote_escape_quoted_data(other), do: {other, false}

  defp prune_quote_escape_quoted_data_each(list) do
    list
    |> Enum.map(&prune_quote_escape_quoted_data/1)
    |> Enum.unzip()
    |> then(fn {nodes, hass} -> {nodes, Enum.any?(hass)} end)
  end

  defp strip_quote_escape_inplace_candidates(node) do
    Candidate.update_candidates(node, fn candidates ->
      Enum.reject(candidates, &match?(%Candidate.InPlace{}, &1))
    end)
  end

  defp quote_escape_binding_pattern_macro?(meta) do
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
end
