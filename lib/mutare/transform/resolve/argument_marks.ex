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
  # `{module, function, arity}`. `Mutare.Transform.Resolve` calls `stamp/5` at each call it resolves,
  # and at each `|>` resolves the RHS target itself and calls `receiver_fun?/2` + `receiver_labels/4`
  # to mark the piped value — stamping the marked argument nodes' `meta[:mutare_marks]` (via
  # `Mutare.Transform.Meta.add_marks/2`) with the union of labels.
  # `Mutare.Transform.Analyze.Attach.offer/4` reads those marks back and hands them to the mutators as
  # `context.marks`. The mutator (`c:Mutare.Mutator.mutate/2`) reads them and decides. See NOTES
  # "Argument marks".
  #
  # Three behaviours fall out of "mark only the value node", rather than being special-cased:
  #
  #   * **Arity-keyed keyword options.** Keyword marks are looked up by the call's *effective* arity
  #     just like positional ones, so `Task.async_stream/3` (fun form) and `/5` (MFA form) — whose
  #     trailing arg is options — can be marked while `/4` — whose trailing arg is the callback
  #     `args` list — is not, leaving a literal there to mutate.
  #   * **Container-preserving scope.** Only the option *value* node is stamped, never the options
  #     *list*, so a list-level mutation (`List` collapsing an explicit `[…]` to `[]`) is untouched —
  #     a marked call behaves exactly like an unmarked one but for the held-back value.
  #   * **Piped receiver.** A pipe's left side is the RHS call's *effective argument 0*, which is not
  #     in the RHS's own arg list. So `stamp/5` (which walks the RHS args) can't reach it; the `|>`
  #     clause resolves the RHS target (`Resolve` owns resolution, so a bare `Kernel`/imported RHS
  #     resolves like a written call) and marks the piped value when effective index 0 carries a mark
  #     (`Process.sleep/1`, `:timer.sleep/1`, or any mutator's index-0 mark). `receiver_funs` is a
  #     cheap pre-filter — the function names that *have* an index-0 mark — so a pipe whose RHS isn't
  #     one of them never pays a resolution.

  alias Mutare.{AST, Mutator}
  alias Mutare.Transform.{Aliases, Meta}

  @typedoc "A resolved-call key: `{module_key, function, arity}` (arity is *effective* — pipe counted)."
  @type call_key :: {Aliases.module_key(), atom(), arity()}

  @typedoc """
  The per-position label sets a call carries: `positional` maps an *effective* argument index to its
  labels, `keyword` maps a trailing-option key to its labels.
  """
  @type entry :: %{
          positional: %{arity() => MapSet.t(atom())},
          keyword: %{atom() => MapSet.t(atom())}
        }

  @typedoc """
  The built registry: `by_call` maps each resolved call to its marked positions; `receiver_funs` is
  the set of function names with a mark at *effective index 0*, a pre-filter for the piped-receiver
  path so ordinary pipes cost nothing.
  """
  @type t :: %__MODULE__{by_call: %{call_key() => entry()}, receiver_funs: MapSet.t(atom())}
  defstruct by_call: %{}, receiver_funs: MapSet.new()

  @doc "The empty registry — no mutator asked to mark anything."
  @spec empty() :: t()
  def empty, do: %__MODULE__{}

  @doc """
  Fold the enabled mutators' `c:Mutare.Mutator.argument_marks/1` declarations into a registry keyed
  by the resolved `{module_key, function, arity}`, encoding each declared module the same way
  `Mutare.Transform.Calls.resolved_call/1` keys on it (so a written `Process` matches a resolved
  `[:Process]`). A mutator without the callback contributes nothing; two mutators marking the same
  position union their labels.
  """
  @spec build([Mutator.Spec.t() | module()]) :: t()
  def build(mutators) do
    by_call =
      mutators
      |> Enum.flat_map(&declarations/1)
      |> Enum.reduce(%{}, &add_declaration/2)

    receiver_funs =
      for {{_module_key, fun, _arity}, entry} <- by_call,
          Map.has_key?(entry.positional, 0),
          into: MapSet.new(),
          do: fun

    %__MODULE__{by_call: by_call, receiver_funs: receiver_funs}
  end

  @doc """
  Stamp the marked argument nodes of a resolved call with their labels, returning the (possibly
  updated) argument list. `pipe_mode` is `:piped` for a `|>` stage — its receiver is effective
  argument 0, so a marked effective index shifts one place off the visible list (and index 0 itself
  is handled by `stamp_receiver/3`). Returns `args` unchanged when the call carries no marks (the
  common path — a cheap map lookup).
  """
  @spec stamp([Macro.t()], Aliases.module_key(), atom(), Mutator.pipe_mode(), t()) :: [Macro.t()]
  def stamp(args, module_key, fun, pipe_mode, %__MODULE__{by_call: by_call}) when is_list(args) do
    offset = pipe_offset(pipe_mode)

    case Map.get(by_call, {module_key, fun, length(args) + offset}) do
      nil -> args
      entry -> args |> stamp_positional(entry.positional, offset) |> stamp_keyword(entry.keyword)
    end
  end

  def stamp(args, _module_key, _fun, _pipe_mode, _registry), do: args

  @doc """
  Whether a pipe's RHS function *could* carry an effective-index-0 mark — the cheap `receiver_funs`
  pre-filter that lets `Mutare.Transform.Resolve` skip resolving the overwhelming majority of pipes.
  Only when this is true does the `|>` clause resolve the RHS target and call `receiver_labels/4`.
  """
  @spec receiver_fun?(Macro.t(), t()) :: boolean()
  def receiver_fun?(rhs, %__MODULE__{receiver_funs: receiver_funs}),
    do: MapSet.member?(receiver_funs, rhs_fun(rhs))

  @doc """
  The effective-index-0 label set for a resolved pipe RHS `{module_key, function, effective_arity}`,
  or `nil`. `Mutare.Transform.Resolve` resolves the target (so bare `Kernel`/imported RHS heads
  resolve the same way as in a written call — not only what `resolved_call/1` alone recovers) and
  hands it here; the piped value is that call's effective argument 0.
  """
  @spec receiver_labels(Aliases.module_key(), atom(), arity(), t()) :: MapSet.t(atom()) | nil
  def receiver_labels(module_key, fun, effective_arity, %__MODULE__{by_call: by_call}) do
    case Map.get(by_call, {module_key, fun, effective_arity}) do
      nil -> nil
      entry -> Map.get(entry.positional, 0)
    end
  end

  # --- registry build --------------------------------------------------------

  # Ask each mutator for its declarations, passing the instance's `config` so a configurable mutator
  # can fold in options-driven positions (e.g. `IntegerLiteral`'s `:skip_arguments`). A bare module
  # carries no config; the `init/1`-normalized `config` is used when present, else the raw `opts`. The
  # instance's `:skip_arguments` marks are relabeled to the instance *name* so two `:as` copies of
  # one module don't collide on a shared module-name label (`relabel_self/2`).
  defp declarations(mutator) do
    module = module_of(mutator)

    if function_exported?(module, :argument_marks, 1),
      do: relabel_self(module.argument_marks(config_of(mutator)), name_of(mutator)),
      else: []
  end

  defp module_of(%Mutator.Spec{module: module}), do: module
  defp module_of(module) when is_atom(module), do: module

  defp config_of(%Mutator.Spec{config: config}), do: config
  defp config_of(_module), do: []

  defp name_of(%Mutator.Spec{name: name}), do: name
  defp name_of(module) when is_atom(module), do: module.name()

  # Relabel the `:skip_arguments` self-marks (`Mutator.self_mark/0`) with the instance name, leaving
  # shared-vocabulary labels (`:timeout`, a custom mutator's own) untouched — so a self-mark suppresses
  # only *this* instance (`Mutator.self_marked?/1`), never a sibling `:as` copy of the same module.
  defp relabel_self(declarations, instance_name) do
    self_mark = Mutator.self_mark()

    Enum.map(declarations, fn
      {mod, fun, arity, positions, ^self_mark} -> {mod, fun, arity, positions, instance_name}
      other -> other
    end)
  end

  # One declaration `{module, fun, arity, positions, label}` → labelled positions folded onto the
  # resolved-call key. `positions` is a list of visible-argument *effective* indices and
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

  defp stamp_positional(args, positional, _offset) when positional == %{}, do: args

  defp stamp_positional(args, positional, offset) do
    args
    |> Enum.with_index()
    |> Enum.map(fn {arg, visible_index} ->
      case Map.get(positional, visible_index + offset) do
        nil -> arg
        labels -> Meta.add_marks(arg, labels)
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
      labels -> {key, Meta.add_marks(value, labels)}
    end
  end

  defp stamp_option_pair(other, _keyword), do: other

  # --- piped receiver --------------------------------------------------------

  # The written function name of a pipe RHS call head (remote `Mod.fun`/`:mod.fun` or bare `fun`), or
  # `nil` for a non-call RHS — never in `receiver_funs`, so the pre-filter rejects it.
  defp rhs_fun({{:., _dot_meta, [_recv, fun]}, _meta, args}) when is_atom(fun) and is_list(args),
    do: fun

  defp rhs_fun({fun, _meta, args}) when is_atom(fun) and is_list(args), do: fun
  defp rhs_fun(_rhs), do: nil

  defp pipe_offset(:piped), do: 1
  defp pipe_offset(_unpiped), do: 0
end
