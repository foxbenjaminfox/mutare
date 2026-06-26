defmodule Mutare.Plugin.Spec do
  @moduledoc """
  A resolved plugin: a `Mutare.Plugin` module plus its per-instance `opts`.

  The plugin counterpart of `Mutare.Mutator.Spec`. A bare module entry in `:plugins`
  resolves to a spec with empty `opts`; a `{module, opts}` entry carries config that is
  delivered to `c:Mutare.Plugin.expand_use/3` through its `context` map's `:opts` key. The
  *registration* callback `c:Mutare.Plugin.macros/0` is opts-independent and never sees them
  — exactly as a mutator's `opts` reach `c:Mutare.Mutator.mutate/2` but not its `macros/0`.
  """

  @enforce_keys [:module]
  defstruct [:module, opts: []]

  @type t :: %__MODULE__{module: module(), opts: keyword()}

  @doc """
  Resolve one `:plugins` entry to a `Spec`: a bare `module` (empty `opts`), a `{module, opts}`
  pair, or an already-resolved `Spec` (idempotent). Raises `ArgumentError` on any other shape.
  Plugin-ness (the module actually implements `Mutare.Plugin`) is checked separately by
  `Mutare.Plugin.validate!/1`; this only resolves the *shape*.
  """
  @spec new(t() | module() | {module(), keyword()}) :: t()
  def new(%__MODULE__{} = spec), do: spec
  def new(module) when is_atom(module), do: %__MODULE__{module: module, opts: []}

  def new({module, opts}) when is_atom(module) and is_list(opts),
    do: %__MODULE__{module: module, opts: opts}

  def new(other) do
    raise ArgumentError,
          "invalid plugin entry: expected a module or a {module, opts} pair, got: #{inspect(other)}"
  end
end
