defmodule Mutare.Transform.QuoteStructure do
  @moduledoc """
  Says which parts of a `quote` run, without walking any of them.

  A `quote` expression that is itself evaluated has three kinds of part, and `parts/1` names
  each value's state:

    * `:live` — an option value (`bind_quoted:`, `unquote:`, `location:`, …). It is ordinary
      code, evaluated where the quote expression is.
    * `:quoted` — the `do:` body while unquoting is enabled. It is data, except for the
      argument of an `unquote`/`unquote_splicing` in it, which is `:live` again.
    * `:inert` — the `do:` body under `unquote: false` or `bind_quoted:` (which disables
      unquoting unless `unquote: true` re-enables it). Nothing in it is ever evaluated.

  Elixir rejects a `quote` whose arguments are not written as lists (a variable, a call), so
  lists are all `parts/1` reads, and anything else is a crash, not a guess. It does accept a
  list element that is no pair (`quote([{:line, 1} | []], do: …)`); that element is `:inert`.

  Inside `:quoted` data, `quoted/1` reads one node: an escape whose argument is `:live`, a
  nested `quote`, or plain data to keep descending. Elixir quotes a nested quote's body with
  unquoting off, so neither `quote(do: quote(do: unquote(f())))` nor its stacked form
  `unquote(unquote(f()))` calls `f/0`, and there is no quote *level* to count: one escape
  leads from `:quoted` to `:live`, and nothing leads out of `:inert`.

  A nested quote's **options** depend on how it is written, because Elixir reads the
  argument count. Given two arguments (`quote bind_quoted: [v: unquote(f())] do … end`) it
  quotes the options as the data around them, escapes still on, and `f/0` runs. Given one
  list holding the options and `do:` together (`quote(bind_quoted: [v: unquote(f())], do: v)`)
  it quotes the whole list with unquoting off, and `f/0` does not run. `quoted/1` returns the
  first as `{:options, options, rebuild}`, with `options` still `:quoted`, and the second as
  `:inert`.

  Resolve, body analysis, self-call rewriting, `super` forwarding and binding analysis share
  this reading, not a traversal: each decides what it does with a live expression, and
  whether a live option is its business at all.
  """

  alias Mutare.AST

  @type state :: :live | :quoted | :inert
  @type rebuild :: ([Macro.t()] -> [Macro.t()])

  @escapes [:unquote, :unquote_splicing]

  @doc """
  The values in a live `quote`'s arguments, in source order, each with its state, and a
  rebuilder that puts replacement values back into the arguments' written shape.
  """
  @spec parts([Macro.t()]) :: {[{Macro.t(), state()}], rebuild()}
  def parts(args) do
    body = if unquote_enabled?(args), do: :quoted, else: :inert
    {Enum.flat_map(args, &arg_parts(&1, body)), &rebuild(args, &1)}
  end

  @doc """
  One node met inside `:quoted` data: `{:escape, argument, rebuild}` when its argument is
  live; for a nested quote, `{:options, options, rebuild}` when its options are still
  `:quoted`, else `:inert`; `:data` for anything else.
  """
  @spec quoted(Macro.t()) ::
          {:escape, Macro.t(), (Macro.t() -> Macro.t())}
          | {:options, Macro.t(), (Macro.t() -> Macro.t())}
          | :inert
          | :data
  def quoted({form, meta, [arg]}) when form in @escapes,
    do: {:escape, arg, &{form, meta, [&1]}}

  def quoted({:quote, meta, [options, body]}),
    do: {:options, options, &{:quote, meta, [&1, body]}}

  # mutare:ignore[guard_drop] equivalent — without it a variable named `quote` reads as `:inert` where it read as `:data`, and a consumer does the same with either: a variable has no children
  def quoted({:quote, _meta, args}) when is_list(args), do: :inert
  def quoted(_node), do: :data

  # Sourceror wraps a keyword list written in brackets; the pairs inside read the same.
  defp arg_parts({:__block__, _meta, [keywords]}, body), do: arg_parts(keywords, body)

  defp arg_parts(keywords, body) do
    Enum.map(keywords, fn
      {key, value} -> {value, if(AST.key_atom(key) == :do, do: body, else: :live)}
      cons -> {cons, :inert}
    end)
  end

  defp rebuild(args, values) do
    {args, []} = Enum.map_reduce(args, values, &rebuild_arg/2)
    args
  end

  defp rebuild_arg({:__block__, meta, [keywords]}, values) do
    {keywords, values} = rebuild_arg(keywords, values)
    {{:__block__, meta, [keywords]}, values}
  end

  defp rebuild_arg(keywords, values) do
    Enum.map_reduce(keywords, values, fn
      {key, _value}, [value | values] -> {{key, value}, values}
      _cons, [value | values] -> {value, values}
    end)
  end

  @missing :__mutare_missing_quote_option__

  # An `unquote:` that is not a literal `false` may be true at runtime, so its body is read
  # as `:quoted`: a walk that treats a dead escape as live withholds or rewrites too much
  # there, where one that ignores a live escape would miss executing code.
  defp unquote_enabled?(args) do
    pairs = option_pairs(args)

    case AST.opts_get(pairs, :unquote, @missing) do
      @missing -> AST.opts_get(pairs, :bind_quoted, @missing) == @missing
      value -> not literal_false?(value)
    end
  end

  defp option_pairs(args) do
    args
    |> Enum.flat_map(fn
      {:__block__, _meta, [keywords]} -> keywords
      keywords -> keywords
    end)
    |> Enum.filter(&match?({_key, _value}, &1))
  end

  defp literal_false?(false), do: true
  defp literal_false?({:__block__, _meta, [false]}), do: true
  defp literal_false?(_other), do: false
end
