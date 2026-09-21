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
      unquoting unless `unquote: true` re-enables it), and anything that is not a keyword
      pair. Nothing in it is ever evaluated.

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
  def parts(args) when is_list(args) do
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

  def quoted({:quote, _meta, args}) when is_list(args), do: :inert
  def quoted(_node), do: :data

  defp arg_parts({:__block__, _meta, [keywords]}, body) when is_list(keywords),
    do: arg_parts(keywords, body)

  defp arg_parts(keywords, body) when is_list(keywords) do
    Enum.map(keywords, fn
      {key, value} -> {value, if(AST.key_atom(key) == :do, do: body, else: :live)}
      other -> {other, :inert}
    end)
  end

  defp arg_parts(other, _body), do: [{other, :inert}]

  defp rebuild(args, values) do
    {args, []} = Enum.map_reduce(args, values, &rebuild_arg/2)
    args
  end

  defp rebuild_arg({:__block__, meta, [keywords]}, values) when is_list(keywords) do
    {keywords, values} = rebuild_arg(keywords, values)
    {{:__block__, meta, [keywords]}, values}
  end

  defp rebuild_arg(keywords, values) when is_list(keywords) do
    Enum.map_reduce(keywords, values, fn
      {key, _value}, [value | values] -> {{key, value}, values}
      _other, [value | values] -> {value, values}
    end)
  end

  defp rebuild_arg(_other, [value | values]), do: {value, values}

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
    Enum.flat_map(args, fn
      {:__block__, _meta, [keywords]} when is_list(keywords) -> Enum.filter(keywords, &pair?/1)
      keywords when is_list(keywords) -> Enum.filter(keywords, &pair?/1)
      _other -> []
    end)
  end

  defp pair?({_key, _value}), do: true
  defp pair?(_other), do: false

  defp literal_false?(false), do: true
  defp literal_false?({:__block__, _meta, [false]}), do: true
  defp literal_false?(_other), do: false
end
