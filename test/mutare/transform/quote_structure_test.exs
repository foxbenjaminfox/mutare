defmodule Mutare.Transform.QuoteStructureTest do
  use ExUnit.Case, async: true

  alias Mutare.AST
  alias Mutare.Transform.QuoteStructure

  # The decoder's claim is about Elixir, so Elixir is the oracle: every `probe(tag)` the
  # decoder calls live must run when the expression is evaluated, and no other may.
  @expressions [
    "quote(do: probe(:body))",
    "quote(do: unquote(probe(:escape)))",
    "quote(do: [probe(:data), unquote_splicing([probe(:splice)])])",
    "quote(do: unquote(probe(:first)) + unquote(probe(:second)))",
    "quote(bind_quoted: [v: probe(:bound)], do: unquote(probe(:disabled_by_bind)))",
    "quote(unquote: false, do: unquote(probe(:disabled)))",
    "quote(bind_quoted: [v: probe(:bound)], unquote: true, do: unquote(probe(:reenabled)))",
    "quote(line: (probe(:line); 7), do: unquote(probe(:escape)))",
    "quote(do: quote(do: probe(:nested_body)))",
    "quote(do: quote(do: unquote(probe(:nested_escape))))",
    "quote(do: quote(do: unquote(unquote(probe(:stacked)))))",
    "quote(do: quote(bind_quoted: [v: unquote(probe(:nested_option))], do: v))",
    "quote(do: quote(unquote: true, do: unquote(probe(:nested_reenabled))))",
    # Two arguments: the nested quote's options are quoted with escapes still on.
    "quote do\n  quote bind_quoted: [v: unquote(probe(:block_option))] do\n    unquote(probe(:block_body))\n  end\nend",
    "quote do\n  quote unquote: unquote(probe(:block_flag)) do\n    v\n  end\nend",
    "quote do\n  quote do\n    quote line: unquote(probe(:deep_option)) do\n      v\n    end\n  end\nend",
    "quote(do: quote([line: unquote(probe(:two_lists))], do: v))",
    "quote(do: unquote(quote(do: unquote(probe(:live_again)))))",
    "quote(do: unquote(quote(do: quote(do: unquote(probe(:inert_again))))))",
    "quote(bind_quoted: [v: quote(do: unquote(probe(:quote_in_option)))], do: v)",
    # Compilable, though no pair: the cons is inert, the body's escape still runs.
    "quote([{:line, 1} | []], do: unquote(probe(:beside_cons)))",
    "quote do\n  probe(:block)\n  unquote(probe(:block_escape))\nend"
  ]

  def probe(tag) do
    Process.put(:probes, [tag | Process.get(:probes, [])])
    tag
  end

  for expression <- @expressions do
    test "live parts are what Elixir evaluates: #{inspect(expression)}" do
      Process.put(:probes, [])
      Code.eval_string("import #{inspect(__MODULE__)}, only: [probe: 1]\n" <> unquote(expression))
      evaluated = Enum.sort(Process.get(:probes))

      for ast <- shapes(unquote(expression)) do
        assert Enum.sort(live_probes(ast, :live)) == evaluated
      end
    end
  end

  test "rebuild restores the written shape and takes replacements in order" do
    for ast <-
          shapes("quote(bind_quoted: [v: 1], unquote: true, do: v)") ++
            shapes("quote do\n  v\nend") do
      {:quote, _meta, args} = ast
      {parts, rebuild} = QuoteStructure.parts(args)

      assert rebuild.(Enum.map(parts, &elem(&1, 0))) == args

      tagged = parts |> Enum.with_index() |> Enum.map(fn {_part, index} -> {:tag, index} end)
      {replaced, _rebuild} = QuoteStructure.parts(rebuild.(tagged))
      assert Enum.map(replaced, &elem(&1, 0)) == tagged
    end
  end

  test "parts names option values live, and the body by whether unquoting is on" do
    states = fn source ->
      {:quote, _meta, args} = Code.string_to_quoted!(source)
      {parts, _rebuild} = QuoteStructure.parts(args)
      Enum.map(parts, &elem(&1, 1))
    end

    assert states.("quote(do: x)") == [:quoted]
    assert states.("quote(location: :keep, do: x)") == [:live, :quoted]
    assert states.("quote(bind_quoted: [v: 1], do: v)") == [:live, :inert]
    assert states.("quote(unquote: false, do: x)") == [:live, :inert]
    assert states.("quote(bind_quoted: [v: 1], unquote: true, do: v)") == [:live, :live, :quoted]
    # Not a literal `false`: it may be true when the quote runs.
    assert states.("quote(unquote: flag, do: x)") == [:live, :quoted]
  end

  test "quoted/1 reads one node and descends nothing" do
    node = &Code.string_to_quoted!/1

    assert {:escape, {:x, _, _}, rebuild} = QuoteStructure.quoted(node.("unquote(x)"))
    assert {:unquote, _, [:replaced]} = rebuild.(:replaced)
    # (Built by hand: the parser wraps a top-level `unquote_splicing` in a block.)
    assert {:escape, _arg, _rebuild} = QuoteStructure.quoted({:unquote_splicing, [], [:xs]})
    assert QuoteStructure.quoted(node.("quote(do: unquote(x))")) == :inert
    assert QuoteStructure.quoted(node.("quote(line: unquote(x), do: y)")) == :inert

    assert {:options, [line: _], rebuild} =
             QuoteStructure.quoted(node.("quote line: unquote(x) do\n  unquote(y)\nend"))

    assert {:quote, _, [:replaced, [do: {:unquote, _, _}]]} = rebuild.(:replaced)
    assert QuoteStructure.quoted(node.("f(unquote(x))")) == :data
    # Two arguments is no escape, only a call with that name in data.
    assert QuoteStructure.quoted({:unquote, [], [1, 2]}) == :data
  end

  defp shapes(source), do: [Code.string_to_quoted!(source), Sourceror.parse_string!(source)]

  # A reference walk over the decoder, collecting the probes it reaches in live code.
  defp live_probes({:probe, _meta, [tag]}, :live), do: [literal(tag)]

  defp live_probes({:quote, _meta, args}, :live) when is_list(args) do
    {parts, _rebuild} = QuoteStructure.parts(args)
    Enum.flat_map(parts, fn {value, state} -> live_probes(value, state) end)
  end

  defp live_probes({_form, _meta, args} = node, :quoted) when is_list(args) do
    case QuoteStructure.quoted(node) do
      {:escape, arg, _rebuild} -> live_probes(arg, :live)
      {:options, options, _rebuild} -> live_probes(options, :quoted)
      :inert -> []
      :data -> children(node, :quoted)
    end
  end

  defp live_probes(_node, :inert), do: []
  defp live_probes(node, state), do: children(node, state)

  defp children({form, _meta, args}, state) when is_list(args),
    do: live_probes(form, state) ++ Enum.flat_map(args, &live_probes(&1, state))

  defp children({left, right}, state), do: live_probes(left, state) ++ live_probes(right, state)
  defp children(list, state) when is_list(list), do: Enum.flat_map(list, &live_probes(&1, state))
  defp children(_leaf, _state), do: []

  defp literal(tag), do: AST.key_atom(tag)
end
