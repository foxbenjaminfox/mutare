defmodule Mutare.Mutator.Spec do
  @moduledoc """
  A resolved mutator module, report name, and per-instance options.

  A bare module uses its `name/0` and receives empty options. A `{module, opts}` entry passes
  `opts` to context-taking callbacks; the reserved `:as` option changes the report and
  `# mutare:ignore` name and is removed before the mutator receives the remaining options.

  The transform also attaches the enclosing module's `@behaviour` set before invoking a mutator.
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
