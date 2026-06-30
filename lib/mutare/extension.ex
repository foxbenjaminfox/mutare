defmodule Mutare.Extension do
  @moduledoc """
  Non-mutating extensions that help Mutare understand source code.

  An extension implements one or both of these behaviours:

    * `Mutare.MacroRouting` — static or shape-aware macro-argument routing;
    * `Mutare.UseExpansion` — an override for a `use` that cannot be expanded normally.

  Extensions do not produce mutations or appear in reports. Add them to `:extensions` as modules
  or `{module, opts}` pairs:

      [extensions: [Mutare.Gettext]]

  Options are passed to `c:Mutare.UseExpansion.expand_use/3`. Macro-routing callbacks do not
  receive extension options. A module that also produces mutations belongs under `:mutators`, not
  `:extensions`.
  """

  alias Mutare.Extension.Spec

  @capability_callbacks [macro_routes: 0, expand_use: 3]

  @doc """
  Returns whether `module` is loaded and implements at least one extension
  capability.
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
  Validates and resolves an `:extensions` list.

  Entries may be modules, `{module, options}` pairs, or resolved
  `Mutare.Extension.Spec` structs. Raises `ArgumentError` for invalid entries.
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
