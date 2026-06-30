defmodule Mutare.MacroRouting do
  @moduledoc """
  Behaviour for describing how Mutare should handle macro arguments.

  Macro arguments may be patterns or compile-time DSL fragments rather than runtime expressions.
  Register those macros with `c:macro_routes/0`. Use a static route when every call has the same
  argument layout, or `:routing` with `c:macro_routing/1` when the layout depends on the call.

  Both extensions and mutators may implement this behaviour. Enabling the module under
  `:extensions` or `:mutators` also enables its routes.

      defmodule MyApp.EctoRouting do
        @behaviour Mutare.MacroRouting

        @impl Mutare.MacroRouting
        def macro_routes do
          [
            {Ecto.Query, :where, :any, :routing},
            {Ecto.Query, :from, 2, [:expression, :skip]}
          ]
        end

        @impl Mutare.MacroRouting
        def macro_routing(call), do: ...
      end

  A route that uses `:hosted` must come from an enabled mutator implementing
  `Mutare.Mutator.MacroHost`. Extensions can classify arguments but cannot host mutations. See
  `Mutare.Macro.Spec` for route forms, wildcards, and treatments.
  """

  @doc """
  Returns macro-route declarations.

  Entries use `{module, name, arity, treatment}` or
  `{module, name, treatment}`. A `:routing` treatment requires
  `macro_routing/1`. A static `:hosted` treatment requires an enabled mutator
  implementing `Mutare.Mutator.MacroHost`.

  Route declarations do not receive per-instance options.
  """
  @callback macro_routes() :: [tuple() | Mutare.Macro.Spec.t()]

  @doc """
  Returns one treatment for each visible argument of a registered macro call.

  Use this callback when routing depends on the call's shape. For a piped call, the
  pipe's left side is not a visible argument and is not included in the result.
  Returned treatments are validated.

  In addition to static treatments, this callback may return:

    * `{:keyword, treatments}` — routes keyword values positionally while leaving
      keys unchanged; extra values default to `:skip`, and nested keyword routing is
      supported
    * `:pinned` — applies configured literal mutations to a scalar DSL value and
      wraps the selector in `^`; use only where the macro accepts interpolation
    * `:hosted` — delegates the position to
      `c:Mutare.Mutator.MacroHost.host/2`; only an enabled hosting mutator may return
      it

  A non-keyword value under `{:keyword, ...}` is left unchanged. Compound values
  cannot use `:pinned` because the selector cannot be pinned at the required depth.
  """
  @callback macro_routing(call_node :: Macro.t()) :: [routing_treatment()]

  @typedoc """
  A treatment returned by `c:macro_routing/1` for one visible argument: a static
  `t:Mutare.Macro.Spec.treatment/0`, `:pinned`, or recursive per-keyword-value routing.
  """
  @type routing_treatment ::
          Mutare.Macro.Spec.treatment()
          | :pinned
          | {:keyword, [keyword_value_treatment()]}

  @typedoc """
  A routing treatment for a value inside `{:keyword, ...}`. The keyword form is recursive, so a
  keyword-list value may itself route each of its values independently.
  """
  @type keyword_value_treatment ::
          :expression
          | :pattern
          | :binding_pattern
          | :skip
          | :hosted
          | :pinned
          | {:keyword, [keyword_value_treatment()]}

  @optional_callbacks macro_routing: 1
end
