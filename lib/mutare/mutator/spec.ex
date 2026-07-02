defmodule Mutare.Mutator.Spec do
  @moduledoc """
  A resolved mutator module, report name, and per-instance options.

  A bare module uses its `name/0` and receives empty options. A `{module, opts}` entry passes
  `opts` to context-taking callbacks; the reserved `:as` option changes the report and
  `# mutare:ignore` name and is removed before the mutator receives the remaining options.

  The transform also attaches the enclosing module's `@behaviour` set before invoking a mutator.
  """

  @enforce_keys [:module, :name]
  defstruct [:module, :name, opts: [], behaviours: MapSet.new(), disabled_callbacks: MapSet.new()]

  @type t :: %__MODULE__{
          module: module(),
          name: atom(),
          opts: term(),
          behaviours: MapSet.t(module()),
          disabled_callbacks: MapSet.t({atom(), arity()})
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
  Builds a spec for `module` with configuration `opts`.

  For keyword options, `:as` overrides the recorded family name and is removed
  before the remaining options are passed to the mutator. Other option values are
  passed through unchanged.

      iex> spec = Mutare.Mutator.Spec.configured(
      ...>   Mutare.Mutators.Arithmetic,
      ...>   as: :strict,
      ...>   threshold: 5
      ...> )
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

  @doc false
  @spec disable_callbacks(t(), [{atom(), arity()}]) :: t()
  def disable_callbacks(%__MODULE__{} = spec, callbacks) when is_list(callbacks) do
    %{spec | disabled_callbacks: MapSet.union(spec.disabled_callbacks, MapSet.new(callbacks))}
  end

  @doc """
  Returns the spec in `specs` for `module`, or `nil`.

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
