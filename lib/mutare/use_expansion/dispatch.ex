defmodule Mutare.UseExpansion.Dispatch do
  @moduledoc false

  alias Mutare.Extension.Spec
  alias Mutare.UseExpansion.{ContractError, Expansion}

  @spec handlers([Spec.t() | module() | {module(), keyword()}]) :: [Spec.t()]
  def handlers(extensions) when is_list(extensions) do
    extensions
    |> Enum.map(&Spec.new/1)
    |> Enum.filter(fn %Spec{module: module} ->
      Code.ensure_loaded?(module) and function_exported?(module, :expand_use, 3)
    end)
  end

  @spec run([Spec.t() | module() | {module(), keyword()}], module(), [Macro.t()], map()) ::
          Mutare.UseExpansion.expansion()
  def run(handlers, used, args, context) when is_list(handlers) do
    handlers
    |> Enum.map(&Spec.new/1)
    |> Enum.find_value(:decline, fn %Spec{module: module, opts: opts} ->
      case safe_expand(module, used, args, Map.put(context, :opts, opts)) do
        :decline -> nil
        %Expansion{} = expansion -> expansion
      end
    end)
  end

  defp safe_expand(module, used, args, context) do
    case module.expand_use(used, args, context) do
      :decline -> :decline
      %Expansion{} = expansion -> expansion
      other -> raise ContractError, message: contract_message(module, other)
    end
  rescue
    error in ContractError -> reraise error, __STACKTRACE__
    error -> reraise ContractError, [message: raised_message(module, error)], __STACKTRACE__
  catch
    kind, value ->
      reraise ContractError, [message: thrown_message(module, kind, value)], __STACKTRACE__
  end

  defp contract_message(module, other) do
    "use-expansion handler #{inspect(module)} returned an invalid result from expand_use/3: " <>
      "#{inspect(other)} — expected a Mutare.UseExpansion.Expansion " <>
      "(build it with Mutare.UseExpansion.expand/2) or :decline"
  end

  defp raised_message(module, error) do
    "use-expansion handler #{inspect(module)} raised in expand_use/3 " <>
      "(#{inspect(error.__struct__)}): #{Exception.message(error)} — return a " <>
      "Mutare.UseExpansion.Expansion or :decline instead"
  end

  defp thrown_message(module, :throw, value) do
    "use-expansion handler #{inspect(module)} threw #{inspect(value)} in expand_use/3 — " <>
      "expected a Mutare.UseExpansion.Expansion or :decline"
  end

  defp thrown_message(module, kind, value) do
    "use-expansion handler #{inspect(module)} signalled #{kind} #{inspect(value)} in " <>
      "expand_use/3 — expected a Mutare.UseExpansion.Expansion or :decline"
  end
end
