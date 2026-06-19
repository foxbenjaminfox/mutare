defmodule Mutare.Mutator.Spec do
  @moduledoc """
  A resolved mutator slot: the module to run, the family name to record, and the
  per-instance `opts` threaded to its callbacks.

  Every mutator runs as a `Spec`, whether or not it was configured —
  `Mutare.Mutators.resolve/1` builds one per entry in a `:mutators` list. A bare
  built-in (`:arithmetic`) or a bare custom module is a `Spec` with empty `opts`
  named by its `name/0`. A `{module, opts}` entry carries `opts`, which the
  transform delivers to the **context-taking callback** — the pipe-aware
  `c:Mutare.Mutator.mutate/2` — via the context map's `:opts` key. (A node-local
  mutator that wants its options must therefore implement `mutate/2`; `mutate/1`
  has no context to carry them.)

  ## Naming / identity

  `name` defaults to `module.name()`. The reserved `:as` key in a keyword `opts`
  overrides it, so the **same module can run twice under distinct names** — which
  matters because the recorded name is what mutant reports show and what the
  `# mutare:ignore[...]` filter matches on, so two configurations must be
  distinguishable. `:as` is consumed here and never reaches the mutator.
  """

  @enforce_keys [:module, :name]
  defstruct [:module, :name, opts: []]

  @type t :: %__MODULE__{module: module(), name: atom(), opts: term()}

  @doc "A spec for a bare module (no opts), named by its `name/0`."
  @spec for_module(module()) :: t()
  def for_module(module) when is_atom(module),
    do: %__MODULE__{module: module, name: module.name(), opts: []}

  @doc """
  A spec for a `{module, opts}` entry. When `opts` is a keyword list, a `:as` key
  overrides the recorded family name and is stripped from the opts passed to the
  mutator; the remainder is the mutator's config. A non-keyword `opts` (e.g. a
  map or any term) is passed through verbatim under the default name.
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

  @doc "Normalize any entry to a spec; a `%Spec{}` passes through unchanged (idempotent)."
  @spec coerce(t() | module()) :: t()
  def coerce(%__MODULE__{} = spec), do: spec
  def coerce(module) when is_atom(module), do: for_module(module)

  @doc "The spec in `specs` whose module is `module`, or `nil` — for the structural families the transform checks by module."
  @spec find([t()], module()) :: t() | nil
  def find(specs, module) when is_list(specs),
    do: Enum.find(specs, &(&1.module == module))
end
