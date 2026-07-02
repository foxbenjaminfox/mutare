defmodule Mutare.Calls do
  @moduledoc """
  Call-resolution readers for custom mutators and macro integrations.

  `resolved_call/1` normalizes qualified, aliased, imported, and Erlang-module calls to
  `{module, function, arguments, rebuild}`. Use `rebuild` to preserve the source's written call
  form when that is compile-safe; bare imported calls may be requalified when the replacement
  changes name or arity. It operates on nodes passed to a mutator by Mutare's transform.

  This reads the `alias`/`import` stamps the transform places on the AST before
  mutators run, so it is only meaningful on a node handed to a mutator by the transform (a
  `mutate/1` argument) — exactly where a call-matching mutator needs it.

  `resolved_macro_call/1` is the **known-macro** twin. It returns a stable
  `Mutare.MacroRouting.Call` with a natural module atom, visible arguments, pipe information, and
  a source-preserving rebuild function.

  `macro_treatment/1` reads *how a node's macro is registered* — the resolved per-argument routing
  the merged registry (built-ins + every mutator's/extension's `macro_routes/0` + the declarative `:macro_routes`
  option) assigned it. A macro host uses it in two places: on its **own** call's `node`, to locate
  the positions the route marked `:hosted` (including values nested under `{:keyword, …}`); and on
  a **nested** macro inside a fragment it walks, to ask whether an argument routes `:skip` (leave
  it opaque) or otherwise specially. In both cases it replaces re-deriving the classification.

  ## Example

      defmodule MyApp.Mutators.Upcase do
        @behaviour Mutare.Mutator
        def name, do: :upcase_swap

        def mutate(node) do
          case Mutare.Calls.resolved_call(node) do
            {[:String], :upcase, [arg], rebuild} -> [rebuild.(:downcase, [arg])]
            _ -> :skip
          end
        end
      end
  """

  # The published facade over `Mutare.Transform.Calls`, the transform's internal reader —
  # extension authors depend on this module; the implementation (and the built-in families)
  # stay free to reach for the internal one directly.

  alias Mutare.Transform

  @typedoc """
  A resolved module: an Elixir-module path (`[:Enum]`, `[:String]`) or an Erlang-module atom
  (`:binary`, `:string`). A mutator keys its table on whichever shape the function lives in.
  """
  @type module_key :: Transform.Calls.module_key()

  @doc """
  Returns `{module, function, arguments, rebuild}` for a resolved standard-library
  call, or `nil`.

  `module` is an Elixir alias path such as `[:String]` or an Erlang module atom.
  `rebuild.(new_function, new_arguments)` preserves the call's written qualifier when safe.
  Remote calls keep their written qualifier or alias. Bare imported calls stay bare for
  value-only replacements, but may be requalified when the replacement changes name or arity.

      iex> node = Sourceror.parse_string!("String.upcase(s)")
      iex> {module, function, arguments, rebuild} =
      ...>   Mutare.Calls.resolved_call(node)
      iex> {module, function}
      {[:String], :upcase}
      iex> Sourceror.to_string(rebuild.(:downcase, arguments))
      "String.downcase(s)"

      iex> erlang = Sourceror.parse_string!(":binary.first(b)")
      iex> {module, function, _arguments, _rebuild} =
      ...>   Mutare.Calls.resolved_call(erlang)
      iex> {module, function}
      {:binary, :first}

      iex> Mutare.Calls.resolved_call(Sourceror.parse_string!("foo(x)"))
      nil
  """
  @spec resolved_call(Macro.t()) ::
          {module_key(), atom(), [Macro.t()], (atom(), [Macro.t()] -> Macro.t())} | nil
  defdelegate resolved_call(node), to: Transform.Calls

  @doc """
  Return the stable call value for a node stamped by the known-macro resolver, or `nil` for any
  other node. Extension callbacks receive this value directly; the reader remains useful to a
  host walking nested macro nodes.
  """
  @spec resolved_macro_call(Macro.t()) :: Mutare.MacroRouting.Call.t() | nil
  defdelegate resolved_macro_call(node), to: Transform.Calls

  @doc """
  Returns the resolved treatment for each visible argument of a registered macro
  call, or `nil`.

  Treatments come from the fully merged macro-routing registry and include any
  shape-aware classification already performed for the call. The result may contain
  static treatments, `:hosted`, or nested keyword routing.

  Inside `c:Mutare.Mutator.MacroHost.host/2`, calling this on the received call's `node` returns
  the treatments that granted hosting, so a host locates its `:hosted` positions without
  re-classifying the call.

  For a piped call, the left side of the pipe is not included. A call that has no
  registered macro route returns `nil`.
  """
  @spec macro_treatment(Macro.t()) :: [Mutare.MacroRouting.routing_treatment()] | nil
  defdelegate macro_treatment(node), to: Transform.Calls
end
