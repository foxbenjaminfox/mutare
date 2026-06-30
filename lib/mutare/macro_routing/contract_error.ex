defmodule Mutare.MacroRouting.ContractError do
  @moduledoc """
  Raised when a macro-routing provider violates the extension contract.

  The structured fields identify the provider, route, callback, rejected value, and reason where
  they are known. Configuration syntax errors remain `ArgumentError`s; this exception is reserved
  for conflicts and callback-backed extension failures.
  """

  defexception [:message, :provider, :route, :callback, :value, :reason]

  @type t :: %__MODULE__{
          message: String.t(),
          provider: module() | nil,
          route: term(),
          callback: {atom(), non_neg_integer()} | nil,
          value: term(),
          reason: atom() | nil
        }

  @doc false
  @spec exception(keyword()) :: t()
  def exception(opts) do
    message = Keyword.get_lazy(opts, :message, fn -> build_message(opts) end)
    struct!(__MODULE__, Keyword.put(opts, :message, message))
  end

  defp build_message(opts) do
    provider = opts |> Keyword.get(:provider) |> describe_provider()
    route = opts |> Keyword.get(:route) |> describe_route()
    callback = opts |> Keyword.get(:callback) |> describe_callback()
    reason = opts |> Keyword.get(:reason, :invalid_contract) |> to_string()

    [provider, callback, route, reason]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp describe_provider(nil), do: "macro-routing provider"
  defp describe_provider(provider), do: inspect(provider)

  defp describe_route(nil), do: ""
  defp describe_route(route), do: "for route #{inspect(route)}"

  defp describe_callback(nil), do: ""
  defp describe_callback({name, arity}), do: "#{name}/#{arity}"
end
