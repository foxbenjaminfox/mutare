defmodule Mutare.Mutator.Spec do
  @moduledoc """
  A resolved mutator slot: the module to run, the family name to record, and the
  per-instance `opts` threaded to its callbacks.

  Every mutator runs as a `Spec`, configured or not — `Mutare.Mutators.resolve/1`
  builds one per entry in a `:mutators` list. A bare built-in (`:arithmetic`) or a
  bare custom module is a `Spec` with empty `opts` named by its `name/0`. A
  `{module, opts}` entry carries `opts`, delivered to `c:Mutare.Mutator.mutate/2`
  via the context map's `:opts` key. (A mutator that wants its options must
  therefore implement `mutate/2`; `mutate/1` has no context to carry them.)

  ## Naming / identity

  `name` defaults to `module.name()`. The reserved `:as` key in a keyword `opts`
  overrides it, so the **same module can run twice under distinct names** — which
  matters because the recorded name is what mutant reports show and what the
  `# mutare:ignore[...]` filter matches on, so two configurations must be
  distinguishable. `:as` is consumed here and never reaches the mutator.

  ## `behaviours` — the enclosing module's behaviour set

  `behaviours` is **not** user config: it is the `MapSet` of behaviour modules the
  enclosing module implements (`@behaviour Foo` directly, or injected by a `use`),
  populated per module by the transform. It is delivered to the context-taking
  callbacks (`c:Mutare.Mutator.mutate/2`, `c:Mutare.Mutator.Structural.return_replacements/2`,
  …) under the context map's `:behaviours` key, so a behaviour-targeted custom
  mutator can gate on it. See `Mutare.Mutator`.
  """

  @enforce_keys [:module, :name]
  defstruct [:module, :name, opts: [], behaviours: MapSet.new()]

  @type t :: %__MODULE__{
          module: module(),
          name: atom(),
          opts: term(),
          behaviours: MapSet.t(module())
        }

  @doc """
  A spec for a bare module (no opts), named by its `name/0`.

      iex> spec = Mutare.Mutator.Spec.for_module(Mutare.Mutators.Arithmetic)
      iex> {spec.module, spec.name, spec.opts}
      {Mutare.Mutators.Arithmetic, :arithmetic, []}
  """
  @spec for_module(module()) :: t()
  def for_module(module) when is_atom(module),
    do: %__MODULE__{module: module, name: module.name(), opts: []}

  @doc """
  A spec for a `{module, opts}` entry. When `opts` is a keyword list, a `:as` key
  overrides the recorded family name and is stripped from the opts passed to the
  mutator; the remainder is the mutator's config.  A non-keyword `opts` (e.g. a
  map or any term) is passed through verbatim under the default name.

      iex> spec = Mutare.Mutator.Spec.configured(Mutare.Mutators.Arithmetic, threshold: 5)
      iex> {spec.name, spec.opts}
      {:arithmetic, [threshold: 5]}

      iex> # `:as` renames the family (so one module can run twice) and is stripped from opts
      iex> spec = Mutare.Mutator.Spec.configured(Mutare.Mutators.Arithmetic, as: :strict, threshold: 5)
      iex> {spec.name, spec.opts}
      {:strict, [threshold: 5]}
  """
  @spec configured(module(), keyword() | term()) :: t()
  def configured(module, opts) when is_atom(module) do
    if Keyword.keyword?(opts) do
      {name, rest} = Keyword.pop(opts, :as)
      %__MODULE__{module: module, name: name || module.name(), opts: rest}
    else
      %__MODULE__{module: module, name: module.name(), opts: opts}
    end
  end

  @doc """
  Normalize any entry to a spec; a `%Spec{}` passes through unchanged (idempotent).

      iex> spec = Mutare.Mutator.Spec.for_module(Mutare.Mutators.Arithmetic)
      iex> Mutare.Mutator.Spec.coerce(spec) == spec
      true
      iex> Mutare.Mutator.Spec.coerce(Mutare.Mutators.Arithmetic) == spec
      true
  """
  @spec coerce(t() | module()) :: t()
  def coerce(%__MODULE__{} = spec), do: spec
  def coerce(module) when is_atom(module), do: for_module(module)

  @doc """
  The spec in `specs` whose module is `module`, or `nil` — for the structural
  families the transform checks by module.

      iex> specs = Mutare.Mutators.resolve([:arithmetic, :relational])
      iex> Mutare.Mutator.Spec.find(specs, Mutare.Mutators.Relational).name
      :relational
      iex> Mutare.Mutator.Spec.find(specs, Enum)
      nil
  """
  @spec find([t()], module()) :: t() | nil
  def find(specs, module) when is_list(specs),
    do: Enum.find(specs, &(&1.module == module))
end
