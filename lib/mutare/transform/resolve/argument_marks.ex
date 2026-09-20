defmodule Mutare.Transform.Resolve.ArgumentMarks do
  @moduledoc false

  # The generic **argument-marking** facility: a way for a mutator to ask the transform to *mark*
  # certain argument positions of certain calls, so the mutator can recognise them later and choose
  # not to mutate there (or mutate differently). The transform stays domain-agnostic — it knows
  # only "position P of call C carries label L" — while the *meaning* of a mark (e.g. "this is a
  # timeout literal") lives entirely in the mutator that requested it
  # (`c:Mutare.Mutator.argument_marks/1`). This is what replaced the hard-coded timeout table that
  # used to live in the transform.
  #
  # Flow: `build/1` folds the enabled mutators' declarations into a registry keyed by the *resolved*
  # `{module, function, arity}`. `Mutare.Transform.Resolve` calls `stamp/4` at each call it resolves,
  # stamping the marked argument nodes' `meta[:mutare_marks]` (via
  # `Mutare.Transform.Meta.add_marks/2`) with the union of labels. A `|>` stage is resolved as the
  # direct call it is sugar for, so its piped operand is marked as argument 0 by the same code.
  # `Mutare.Transform.Analyze.Attach.offer/4` reads those marks back and hands them to the mutators as
  # `context.marks`. The mutator (`c:Mutare.Mutator.mutate/2`) reads them and decides. See NOTES
  # "Argument marks".
  #
  # Two behaviours fall out of "mark only the value node", rather than being special-cased:
  #
  #   * **Arity-keyed keyword options.** Keyword marks are looked up by the call's *effective* arity
  #     just like positional ones, so `Task.async_stream/3` (fun form) and `/5` (MFA form) — whose
  #     trailing arg is options — can be marked while `/4` — whose trailing arg is the callback
  #     `args` list — is not, leaving a literal there to mutate.
  #   * **Container-preserving scope.** Only the option *value* node is stamped, never the options
  #     *list*, so a list-level mutation (`List` collapsing an explicit `[…]` to `[]`) is untouched —
  #     a marked call behaves exactly like an unmarked one but for the held-back value.

  alias Mutare.{AST, Mutator}
  alias Mutare.Transform.{Aliases, Meta}

  @typedoc "A resolved-call key: `{module_key, function, arity}` (a piped operand counts as an argument)."
  @type call_key :: {Aliases.module_key(), atom(), arity()}

  @typedoc """
  The per-position label sets a call carries: `positional` maps an argument index to its labels, `keyword` maps a trailing-option key to its labels.
  """
  @type entry :: %{
          positional: %{arity() => MapSet.t(atom())},
          keyword: %{atom() => MapSet.t(atom())}
        }

  @typedoc "The built registry: each resolved call's marked positions."
  @type t :: %__MODULE__{by_call: %{call_key() => entry()}}
  defstruct by_call: %{}

  @doc "The empty registry — no mutator asked to mark anything."
  @spec empty() :: t()
  def empty, do: %__MODULE__{}

  @doc """
  Fold the enabled mutators' `c:Mutare.Mutator.argument_marks/1` declarations — plus the user's
  `argument_marks:` configuration, a run-level declarer with the same declaration shape — into a
  registry keyed by the resolved `{module_key, function, arity}`, encoding each declared module the
  same way `Mutare.Transform.Calls.resolved_call/1` keys on it (so a written `Process` matches a
  resolved `[:Process]`). A mutator without the callback contributes nothing; two declarers marking
  the same position union their labels.
  """
  @spec build([Mutator.Spec.t() | module()], [Mutator.mark_declaration()]) :: t()
  def build(mutators, configured \\ []) do
    by_call =
      mutators
      |> Enum.flat_map(&declarations/1)
      |> Kernel.++(configured)
      |> Enum.reduce(%{}, &add_declaration/2)

    %__MODULE__{by_call: by_call}
  end

  @doc """
  Stamp the marked argument nodes of a resolved call with their labels, returning the (possibly
  updated) argument list. Returns `args` unchanged when the call carries no marks (the common
  path — a cheap map lookup).
  """
  @spec stamp([Macro.t()], Aliases.module_key(), atom(), t()) :: [Macro.t()]
  def stamp(args, module_key, fun, %__MODULE__{by_call: by_call}) when is_list(args) do
    case Map.get(by_call, {module_key, fun, length(args)}) do
      nil -> args
      entry -> args |> stamp_positional(entry.positional) |> stamp_keyword(entry.keyword)
    end
  end

  def stamp(args, _module_key, _fun, _registry), do: args

  @doc """
  Stamp a call's meta with the `{module_key, fun, arity}` key of the mark declaration it
  matched (`Mutare.Transform.Meta.stamp_mark_call/2`), or return `meta` unchanged when none does.
  Read back by `Mutare.Transform.ConfigMatches` so a configured `argument_marks:` entry that
  reached no call can be reported.
  """
  @spec stamp_call(keyword(), Aliases.module_key(), atom(), arity(), t()) :: keyword()
  def stamp_call(meta, module_key, fun, arity, %__MODULE__{by_call: by_call}) do
    key = {module_key, fun, arity}
    if Map.has_key?(by_call, key), do: Meta.stamp_mark_call(meta, key), else: meta
  end

  @doc """
  Whether the registry declares any mark for `{module_key, fun, arity}` — the probe behind
  `Mutare.Transform.Resolve`'s whole-import fallback. `Imports.stamp` resolves a whole `import Mod`
  by reflection, so a module defined only in the target project (which the Mutare process can't
  load) leaves the bare call unresolved — but the declaration itself asserts the module provides
  `fun/arity`, and the compile-unambiguity rule makes a bare call under a whole import of that
  module unambiguously it. The resolver uses this so a declared mark still applies to the
  imported bare form (same reasoning as its known-macro registry fallback).
  """
  @spec declares?(t(), Aliases.module_key(), atom(), arity()) :: boolean()
  def declares?(%__MODULE__{by_call: by_call}, module_key, fun, arity),
    do: Map.has_key?(by_call, {module_key, fun, arity})

  # Stamp a marked argument node with `labels`, reaching *inside* a unary-signed numeric literal. A
  # negative (or explicitly `+`) literal parses as `{:-/:+, _, [positive_literal]}`, and the value
  # families (`IntegerLiteral`/`FloatLiteral`) fire on that *inner* literal — so a bare outer stamp
  # would let `MyApp.put(c, -300)` slip past a mark that catches `MyApp.put(c, 300)`.
  # Marks both the sign node and the inner literal; every other node is stamped as-is.
  defp mark_argument({op, _meta, [{:__block__, _, [n]}]} = node, labels)
       when op in [:-, :+] and is_number(n) do
    {^op, meta, [inner]} = Meta.add_marks(node, labels)
    {op, meta, [Meta.add_marks(inner, labels)]}
  end

  defp mark_argument(node, labels), do: Meta.add_marks(node, labels)

  # --- registry build --------------------------------------------------------

  # Ask each mutator for its declarations, passing the instance's `config` so a configurable mutator
  # can fold in options-driven positions. A bare module carries no config; the `init/1`-normalized
  # `config` is used when present, else the raw `opts`.
  defp declarations(mutator) do
    module = module_of(mutator)

    if function_exported?(module, :argument_marks, 1),
      do: module.argument_marks(config_of(mutator)),
      else: []
  end

  defp module_of(%Mutator.Spec{module: module}), do: module
  defp module_of(module) when is_atom(module), do: module

  defp config_of(%Mutator.Spec{config: config}), do: config
  defp config_of(_module), do: []

  # One declaration `{module, fun, arity, positions, label}` → labelled positions folded onto the
  # resolved-call key. `positions` is a list of argument indices and
  # `{:keyword, key}` option keys.
  defp add_declaration({module, fun, arity, positions, label}, by_call) do
    key = {Aliases.from_module(module), fun, arity}
    entry = Map.get(by_call, key, %{positional: %{}, keyword: %{}})
    Map.put(by_call, key, Enum.reduce(positions, entry, &add_position(&2, &1, label)))
  end

  defp add_position(entry, index, label) when is_integer(index),
    do:
      update_in(
        entry.positional,
        &Map.update(&1, index, MapSet.new([label]), fn s -> MapSet.put(s, label) end)
      )

  defp add_position(entry, {:keyword, key}, label) when is_atom(key),
    do:
      update_in(
        entry.keyword,
        &Map.update(&1, key, MapSet.new([label]), fn s -> MapSet.put(s, label) end)
      )

  # --- stamping --------------------------------------------------------------

  defp stamp_positional(args, positional) when positional == %{}, do: args

  defp stamp_positional(args, positional) do
    args
    |> Enum.with_index()
    |> Enum.map(fn {arg, index} ->
      case Map.get(positional, index) do
        nil -> arg
        labels -> mark_argument(arg, labels)
      end
    end)
  end

  defp stamp_keyword(args, keyword) when keyword == %{}, do: args
  defp stamp_keyword([], _keyword), do: []

  defp stamp_keyword(args, keyword) do
    {init, [last]} = Enum.split(args, -1)
    init ++ [stamp_options(last, keyword)]
  end

  # The trailing options argument, in either shape: the bare `k: v` sugar (a keyword list) or an
  # explicit `[k: v]` literal (which Sourceror wraps in a single-element `__block__`). Stamp the
  # value of each marked key; leave the key, its neighbours, and the list wrapper untouched.
  defp stamp_options({:__block__, meta, [inner]}, keyword) when is_list(inner),
    do: {:__block__, meta, [stamp_options(inner, keyword)]}

  defp stamp_options(kw, keyword) when is_list(kw),
    do: Enum.map(kw, &stamp_option_pair(&1, keyword))

  defp stamp_options(other, _keyword), do: other

  defp stamp_option_pair({key, value}, keyword) do
    case Map.get(keyword, AST.key_atom(key)) do
      nil -> {key, value}
      labels -> {key, mark_argument(value, labels)}
    end
  end

  defp stamp_option_pair(other, _keyword), do: other
end
