defmodule Mutare.Extension do
  @moduledoc """
  Validation and configuration boundary for non-mutating source-understanding extensions.

  `:extensions` accepts modules implementing one or both independent capabilities:

    * `Mutare.MacroRouting` — static macro-argument routing through `macro_routes/0`;
    * `Mutare.UseExpansion` — `use`-expansion overrides through `expand_use/3`.

  An extension acts only while Mutare understands and transforms source. It produces no mutation,
  consumes no runner slot, and never appears in a report. A module may implement both capabilities
  so a library integration remains one configuration entry:

      [extensions: [Mutare.Gettext]]

  Entries may be bare modules or `{module, opts}` pairs. Options are delivered only to
  `c:Mutare.UseExpansion.expand_use/3`; static `c:Mutare.MacroRouting.macro_routes/0` declarations
  are intentionally options-independent.

  Mutators may implement `Mutare.MacroRouting` too, but belong under `:mutators`. They are rejected
  from `:extensions` so their mutation producers cannot be enabled accidentally as routing-only
  modules.
  """

  alias Mutare.Extension.Spec

  @capability_callbacks [macro_routes: 0, expand_use: 3]

  @doc """
  Whether `module` is a loaded, non-mutating extension exporting at least one extension
  capability callback.
  """
  @spec extension?(term()) :: boolean()
  def extension?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and not mutator?(module) and
      Enum.any?(@capability_callbacks, fn {fun, arity} ->
        function_exported?(module, fun, arity)
      end)
  end

  def extension?(_other), do: false

  @doc """
  Validate and resolve an `:extensions` value to `Mutare.Extension.Spec`s.

  Accepts a list of bare modules, `{module, opts}` pairs, or already-resolved specs. Invalid
  entries fail loudly rather than being silently ignored by capability-specific collectors.
  """
  @spec validate!(term()) :: [Spec.t()]
  def validate!(extensions) when is_list(extensions),
    do: Enum.map(extensions, &validate_entry!/1)

  def validate!(other) do
    raise ArgumentError,
          ":extensions must be a list of extension modules or {module, opts} pairs, got: " <>
            inspect(other)
  end

  defp validate_entry!(entry), do: entry |> Spec.new() |> ensure_extension!()

  defp ensure_extension!(%Spec{module: module, opts: opts} = spec) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError,
            ":extensions entry opts must be a keyword list, got: #{inspect(opts)} " <>
              "(for #{inspect(module)})"
    end

    unless extension?(module) do
      raise ArgumentError,
            ":extensions entries must be loaded non-mutator modules implementing " <>
              "Mutare.MacroRouting and/or Mutare.UseExpansion " <>
              "(exporting macro_routes/0 or expand_use/3), got: #{inspect(module)}"
    end

    spec
  end

  defp mutator?(module) do
    declared = module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
    Mutare.Mutator in declared
  rescue
    _ -> false
  end
end
