defmodule Mutare.Transform.Analyze.CallOptions do
  @moduledoc false

  # The "call-option key" sub-concern of the analyze pass: detecting that a runtime
  # node is a *call* whose trailing argument is a keyword list, and tagging that list's
  # *key* candidates `call_option_key?` so emission (`Transform.gate_candidates/1`) can
  # drop them for a mutator configured `{Module, call_option_keys: false}`. A pure leaf —
  # it transforms an already-analyzed node and never calls back into the descent.
  #
  # `Mutare.Transform.Analyze` runs `mark/1` over every runtime call (`recurse_runtime/2`)
  # and over a known macro's offered node; `keyword_list_shaped?/1` is the generic
  # keyword-list predicate also shared by the known-macro keyword routing.

  alias Mutare.Transform.Candidate

  # Data/structural forms that reach the generic runtime clause but are *not* calls,
  # so a keyword-list-shaped trailing element (a `%{a: 1}` pair list, a `{a, [b: 1]}`
  # tuple's last element) is never mistaken for a call's trailing options (`call_form?/1`).
  @non_call_forms [:{}, :%{}, :<<>>, :__block__, :__aliases__]

  # When this runtime node is a *call* whose final argument is a keyword list
  # (`foo(x, timeout: 5, retries: 3)` — the trailing-keyword sugar, the same AST as
  # an explicit `[timeout: 5, …]` last arg), tag each of that list's *key* candidates
  # `call_option_key?`. Emission (`Transform.gate_candidates/1`) then drops a tagged
  # candidate whose mutator was configured `{Module, call_option_keys: false}` — leaving
  # that option name unmutated while its value still mutates. A data/structural form
  # (`%{}`, a 3+-tuple) is not a call, so its trailing element is left alone; only the
  # call context (known here) can make this distinction. The marking is shallow: nested
  # maps/lists inside an option *value* keep their own keys.
  @spec mark(Macro.t()) :: Macro.t()
  def mark({form, meta, args} = node) when is_list(args) and args != [] do
    last = List.last(args)

    if call_form?(form) and keyword_list_shaped?(last) do
      {init, [_last]} = Enum.split(args, -1)
      {form, meta, init ++ [tag_option_keys(last)]}
    else
      node
    end
  end

  def mark(node), do: node

  @doc """
  Whether `list` is a non-empty list every element of which is a `{key, value}` pair —
  the AST shape of a keyword list (a call's trailing options, or an explicit `[k: v]`).
  Shared by `mark/1` and the known-macro keyword routing.
  """
  @spec keyword_list_shaped?(term()) :: boolean()
  def keyword_list_shaped?(list) when is_list(list) and list != [],
    do: Enum.all?(list, &match?({_k, _v}, &1))

  def keyword_list_shaped?(_other), do: false

  # A genuine call: a remote `Foo.bar(…)` (`{:., …}` form) or a local/operator call (an
  # atom form), minus the data/structural forms that also reach the generic runtime
  # clause and could carry a keyword-list-shaped trailing element without being a call.
  defp call_form?({:., _meta, _args}), do: true
  defp call_form?(form) when is_atom(form), do: form not in @non_call_forms
  defp call_form?(_form), do: false

  defp tag_option_keys(kw) do
    Enum.map(kw, fn
      {key, value} -> {tag_option_key(key), value}
      other -> other
    end)
  end

  # Stamp `call_option_key?` onto each candidate already attached to a key node. A key
  # with no candidates (a block key, or a key no mutator matched) is left untouched.
  defp tag_option_key(key),
    do: Candidate.update_candidates(key, fn cands -> Enum.map(cands, &as_call_option/1) end)

  defp as_call_option(%Candidate.InPlace{} = c), do: %{c | call_option_key?: true}
  defp as_call_option(other), do: other
end
