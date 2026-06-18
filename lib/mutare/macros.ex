defmodule Mutare.Macros do
  @moduledoc """
  The catalog of **known macros** — macros whose arguments the transform routes by
  a declared treatment instead of the default all-runtime descent.

  The counterpart to `Mutare.Mutators`, but for *argument routing* rather than node
  mutation. A `Mutare.Macro.Spec` says, per argument, whether it is an
  `:expression` (mutate), a `:pattern` (a match context — descend but don't mutate
  the pattern), or `:skip` (leave raw — an opaque DSL body). Specs come from three
  sources, merged (later overrides earlier):

    * **built-ins** (`builtin/0`) — `Kernel.match?/2` and `Kernel.destructure/2`,
      both routing argument 0 as a pattern. Always on.
    * the declarative **`:macros`** option (`.mutare.exs` / `Mutare.run/2`) — a list
      of `{module, name, arity, treatment}` / `{module, name, treatment}` entries,
      resolved by `resolve/1`.
    * an optional **`c:Mutare.Mutator.macros/0`** callback on any enabled mutator
      (`from_mutators/1`) — so a library ships its custom mutator *and* the macro
      registration it relies on in one module, and the user adds a single
      `:mutators` entry. Mutare core never needs to know about the library.

  `build/2` merges the three into a lookup keyed `{module_key, name, arity}` (with
  an `:any`-arity fallback); `routing/4` reads it during the lexical resolution
  pre-pass (`Mutare.Transform.Resolve`), which stamps a matched call so the analyzer
  routes its arguments.

  Resolution of declarative entries is **purely syntactic** (no reflection on the
  module), so a `{Ecto.Query, :from, :any, :skip}` entry resolves even when `Ecto`
  is not a dependency of the Mutare process.
  """

  alias Mutare.Macro.Spec
  alias Mutare.Mutator

  # The built-in known macros, as plain `{module, name, arity, args}` tuples run
  # through the same `resolve/1` as user entries — one validation/normalization
  # path, like `Mutare.Mutators.all/0` derives from its `@registry`.
  #
  #   * `Kernel.match?(pattern, expr)` — arg 0 is a match context (it expands to
  #     `case expr do pattern -> true; _ -> false end`); a literal there is a
  #     pattern, not a value.
  #   * `Kernel.destructure(left, right)` — arg 0 is a list of variables matched
  #     against `right` (padding with `nil`), i.e. a pattern position.
  @builtin [
    {Kernel, :match?, 2, [:pattern, :expression]},
    {Kernel, :destructure, 2, [:pattern, :expression]}
  ]

  @typedoc "A merged registry: a lookup from `{module_key, name, arity}` to its `Spec`."
  @type registry :: %{optional({Spec.module_key(), atom(), non_neg_integer() | :any}) => Spec.t()}

  @doc "The built-in known-macro specs (`Kernel.match?/2`, `Kernel.destructure/2`)."
  @spec builtin() :: [Spec.t()]
  def builtin, do: resolve(@builtin)

  @doc """
  Resolve a list of declarative macro entries into `Mutare.Macro.Spec`s.

  Each entry is a `{module, name, arity, treatment}` 4-tuple, a
  `{module, name, treatment}` 3-tuple (arity `:any`), or an already-resolved
  `%Mutare.Macro.Spec{}` (idempotent). Raises `ArgumentError` on a malformed entry.
  """
  @spec resolve([tuple() | Spec.t()] | term()) :: [Spec.t()]
  def resolve(entries) when is_list(entries), do: Enum.map(entries, &resolve!/1)

  def resolve(other),
    do: raise(ArgumentError, ":macros must be a list of macro entries, got: #{inspect(other)}")

  defp resolve!(%Spec{} = spec), do: spec
  defp resolve!({module, name, arity, args}), do: Spec.new(module, name, arity, args)
  defp resolve!({module, name, args}), do: Spec.new(module, name, :any, args)

  defp resolve!(other) do
    raise ArgumentError,
          "a macro entry must be {module, name, arity, treatment} or {module, name, treatment}, " <>
            "got: #{inspect(other)}"
  end

  @doc """
  Collect macro specs contributed by enabled mutators via the optional
  `c:Mutare.Mutator.macros/0` callback.

  `mutator_specs` are resolved `Mutare.Mutator.Spec`s; each distinct module that is
  loaded and exports `macros/0` contributes its entries (resolved like declarative
  ones). A module is consulted once even if listed twice.
  """
  @spec from_mutators([Mutator.Spec.t()]) :: [Spec.t()]
  def from_mutators(mutator_specs) when is_list(mutator_specs) do
    mutator_specs
    |> Enum.map(& &1.module)
    |> Enum.uniq()
    |> Enum.filter(&exports_macros?/1)
    |> Enum.flat_map(& &1.macros())
    |> resolve()
  end

  defp exports_macros?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :macros, 0)

  @doc """
  Build the merged lookup registry from declarative `:macros` entries and the
  enabled mutator specs.

  Order is built-ins, then declarative `:macros`, then mutator-provided — folded
  with `Map.put`, so a later entry for the same `{module_key, name, arity}`
  overrides an earlier one (config and mutator-provided override built-ins).
  `config_macros` may be raw entries or already-resolved specs (idempotent).
  """
  @spec build([tuple() | Spec.t()], [Mutator.Spec.t()]) :: registry()
  def build(config_macros, mutator_specs) do
    (builtin() ++ resolve(config_macros) ++ from_mutators(mutator_specs))
    |> Enum.reduce(%{}, fn spec, acc -> Map.put(acc, Spec.key(spec), spec) end)
  end

  @doc """
  The per-position argument routing for a call resolving to `module_key`/`name` at
  `arity`, or `nil` when no known macro matches. An exact `arity` match wins over an
  `:any`-arity entry.
  """
  @spec routing(registry(), Spec.module_key(), atom(), non_neg_integer()) ::
          [Spec.treatment()] | nil
  def routing(registry, module_key, name, arity) when is_map(registry) do
    case Map.get(registry, {module_key, name, arity}) ||
           Map.get(registry, {module_key, name, :any}) do
      nil -> nil
      %Spec{} = spec -> Spec.routing(spec, arity)
    end
  end
end
