defmodule Mutare.Extension do
  @moduledoc """
  Non-mutating extensions for call routing, `use` expansion, and coverage attribution.

  An extension implements one or more of these behaviours:

    * `Mutare.CallRouting` — static or shape-aware macro-argument routing;
    * `Mutare.UseExpansion` — an override for a `use` that cannot be expanded normally;
    * `Mutare.CoverageAttribution` — hooks, installed in the coverage probe's test VM,
      that tell Mutare which test a process with no lineage link to one is working for.

  Extensions do not produce mutations or appear in reports. Add them to `:extensions` as modules or `{module, opts}` pairs:

      [extensions: [Mutare.Gettext]]

  Entries may be bare modules or `{module, opts}` pairs. Options are delivered to `c:Mutare.UseExpansion.expand_use/3` and `c:Mutare.CoverageAttribution.attach_attribution/1`; `c:Mutare.CallRouting.call_routes/0` declarations and `c:Mutare.CallRouting.route_arguments/1` classification are intentionally options-independent. The probe's test VM receives `attach_attribution/1`'s options as written-out source, so an extension exporting it must be given plain data (atoms, numbers, strings, and lists, tuples and maps of them); anything else is refused here.

  Mutators may implement `Mutare.CallRouting` too, but belong under `:mutators`. They are rejected from `:extensions` so their mutation producers cannot be enabled accidentally as routing-only modules.

  An extension that routes a library's DSL may declare that library's modules by exporting `required_modules/0` (the same optional callback mutators declare — see `c:Mutare.Mutator.required_modules/0`); `validate!/1` checks each is loadable and aborts with a `Mutare.EnvironmentError` otherwise, so an external-source run fails loudly at startup instead of silently registering routes against nothing.
  """

  alias Mutare.Extension.Spec

  @capability_callbacks [call_routes: 0, expand_use: 3, attach_attribution: 1]

  @doc """
  Returns whether `module` is loaded and implements at least one extension
  capability.
  """
  @spec extension?(term()) :: boolean()
  def extension?(module) when is_atom(module) do
    not mutator?(module) and
      Enum.any?(@capability_callbacks, fn {fun, arity} ->
        Mutare.Reflection.exports?(module, fun, arity)
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
              "Mutare.CallRouting, Mutare.UseExpansion, or Mutare.CoverageAttribution " <>
              "(exporting call_routes/0, expand_use/3, or attach_attribution/1), got: " <>
              inspect(module)
    end

    if Mutare.Reflection.exports?(module, :attach_attribution, 1) and not plain_data?(opts) do
      raise ArgumentError,
            ":extensions entry opts for #{inspect(module)} reach attach_attribution/1 in the " <>
              "coverage probe's test VM as source, so they must be plain data (atoms, numbers, " <>
              "strings, and lists, tuples and maps of them), got: #{inspect(opts)}"
    end

    Mutare.EnvironmentError.verify!(module)
    spec
  end

  # Whether `term` is written out as source that evaluates back to it: no pid, port, reference
  # or function, which `Macro.escape/1` either refuses or renders as text that does not parse.
  defp plain_data?(term)
       when is_atom(term) or is_number(term) or is_binary(term),
       do: true

  defp plain_data?(list) when is_list(list), do: plain_list?(list)
  defp plain_data?(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> plain_list?()

  defp plain_data?(map) when is_map(map) do
    Enum.all?(Map.to_list(map), fn {key, value} -> plain_data?(key) and plain_data?(value) end)
  end

  defp plain_data?(_other), do: false

  # Improper lists included: `[a | b]` is plain when `a` and `b` are.
  defp plain_list?([]), do: true
  defp plain_list?([head | tail]), do: plain_data?(head) and plain_list?(tail)
  defp plain_list?(tail), do: plain_data?(tail)

  # Same rule as `Mutare.Mutators.resolve/1`: a mutator is recognised by what it exports
  # (`name/0` + a producing callback), never by a `@behaviour` attribute — so a module that
  # exports `mutate/1` without the attribute line is still refused as an extension.
  defp mutator?(module), do: Mutare.Mutator.Dispatch.implemented_by?(module)
end
