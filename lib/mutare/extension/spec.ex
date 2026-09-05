defmodule Mutare.Extension.Spec do
  @moduledoc """
  A resolved non-mutating extension module and its per-instance options.

  A bare module in `:extensions` resolves with empty options. A `{module, opts}` entry carries configuration to `c:Mutare.UseExpansion.expand_use/3` through `context.opts`. `Mutare.CallRouting` callbacks never receive these options.
  """

  @enforce_keys [:module]
  defstruct [:module, opts: []]

  @type t :: %__MODULE__{module: module(), opts: keyword()}

  @doc """
  Resolve one `:extensions` entry to a spec. Capability validation is performed by
  `Mutare.Extension.validate!/1`.

  ## Examples

      iex> Mutare.Extension.Spec.new(Enum)
      %Mutare.Extension.Spec{module: Enum, opts: []}

      iex> Mutare.Extension.Spec.new({Enum, [domain: "errors"]}).opts
      [domain: "errors"]
  """
  @spec new(t() | module() | {module(), keyword()}) :: t()
  def new(%__MODULE__{} = spec), do: spec
  def new(module) when is_atom(module), do: %__MODULE__{module: module, opts: []}

  def new({module, opts}) when is_atom(module) and is_list(opts),
    do: %__MODULE__{module: module, opts: opts}

  def new(other) do
    raise ArgumentError,
          "invalid extension entry: expected a module or a {module, opts} pair, got: " <>
            inspect(other)
  end
end
