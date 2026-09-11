defmodule Mutare.Extension do
  @moduledoc """
  Non-mutating extensions that help Mutare understand source code.

  An extension implements one or both of these behaviours:

    * `Mutare.CallRouting` — static or shape-aware macro-argument routing;
    * `Mutare.UseExpansion` — an override for a `use` that cannot be expanded normally.

  Extensions do not produce mutations or appear in reports. Add them to `:extensions` as modules or `{module, opts}` pairs:

      [extensions: [Mutare.Gettext]]

  Entries may be bare modules or `{module, opts}` pairs. Options are delivered only to `c:Mutare.UseExpansion.expand_use/3`; `c:Mutare.CallRouting.call_routes/0` declarations and `c:Mutare.CallRouting.route_arguments/2` classification are intentionally options-independent.

  Mutators may implement `Mutare.CallRouting` too, but belong under `:mutators`. They are rejected from `:extensions` so their mutation producers cannot be enabled accidentally as routing-only modules.

  An extension that routes a library's DSL may declare that library's modules by exporting `required_modules/0` (the same optional callback mutators declare — see `c:Mutare.Mutator.required_modules/0`); `validate!/1` checks each is loadable and aborts with a `Mutare.EnvironmentError` otherwise, so an external-source run fails loudly at startup instead of silently registering routes against nothing.
  """

  alias Mutare.Extension.Spec

  @capability_callbacks [call_routes: 0, expand_use: 3]

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
              "Mutare.CallRouting and/or Mutare.UseExpansion " <>
              "(exporting call_routes/0 or expand_use/3), got: #{inspect(module)}"
    end

    Mutare.EnvironmentError.verify!(module)
    spec
  end

  # Same rule as `Mutare.Mutators.resolve/1`: a mutator is recognised by what it exports
  # (`name/0` + a producing callback), never by a `@behaviour` attribute — so a module that
  # exports `mutate/1` without the attribute line is still refused as an extension.
  defp mutator?(module), do: Mutare.Mutator.Dispatch.implemented_by?(module)
end
