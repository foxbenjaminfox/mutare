defmodule Mutare.EnvironmentError do
  @moduledoc """
  A plugin's declared environment is not satisfied: a module it listed in
  `c:Mutare.Mutator.required_modules/0` is not loadable in the Mutare process.

  Raised once at startup — when a `:mutators` entry is resolved to a
  `Mutare.Mutator.Spec`, or an `:extensions` entry is validated by
  `Mutare.Extension.validate!/1` — before any source is read, so a plugin whose
  routing would silently register against nothing fails loudly instead. The
  message is core-owned and names the plugin, the missing modules, and the
  deployment requirement.

  Structured fields:

    * `:plugin` — the plugin module whose requirement failed;
    * `:missing` — the declared modules that are not loadable (a subset of the
      plugin's `required_modules/0`).
  """

  defexception [:plugin, :missing]

  @type t :: %__MODULE__{plugin: module(), missing: [module()]}

  @impl Exception
  def message(%__MODULE__{plugin: plugin, missing: missing}) do
    "#{inspect(plugin)} requires #{names(missing)}, which #{verb(missing)} not loadable in " <>
      "this Mutare process. A plugin that routes a library's DSL must run as a dependency " <>
      "of the app under test — add it to that app's deps and run `mix mutare` there. " <>
      "External-source operation is not supported for this plugin."
  end

  @doc """
  Verifies `plugin`'s declared environment, raising when it is not satisfied.

  When `plugin` exports `required_modules/0` (see
  `c:Mutare.Mutator.required_modules/0`), each declared module is checked
  loadable (`Code.ensure_loaded?/1`); any missing module raises this error. A
  module without the callback — or one that is itself not loadable, which other
  validation reports — passes unchecked. Raises `ArgumentError` when the
  callback returns anything but a list of modules.
  """
  @spec verify!(module()) :: :ok
  def verify!(plugin) when is_atom(plugin) do
    if Code.ensure_loaded?(plugin) and function_exported?(plugin, :required_modules, 0) do
      missing =
        plugin.required_modules()
        |> declared!(plugin)
        |> Enum.reject(&Code.ensure_loaded?/1)

      case missing do
        [] -> :ok
        missing -> raise __MODULE__, plugin: plugin, missing: missing
      end
    else
      :ok
    end
  end

  defp declared!(modules, plugin) do
    unless is_list(modules) and Enum.all?(modules, &is_atom/1) do
      raise ArgumentError,
            "#{inspect(plugin)}.required_modules/0 must return a list of modules, got: " <>
              inspect(modules)
    end

    modules
  end

  defp names([_ | _] = missing), do: Enum.map_join(missing, " and ", &inspect/1)

  defp verb([_single]), do: "is"
  defp verb(_several), do: "are"
end
