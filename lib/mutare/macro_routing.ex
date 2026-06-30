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
  Register macro routes as `{module, name, arity, treatment}` or
  `{module, name, treatment}` entries.

  A treatment may be static or the `:routing` sentinel. `:routing` requires
  `c:macro_routing/1`; a static `:hosted` treatment requires
  `c:Mutare.Mutator.MacroHost.host/2` on an enabled mutator.

  These declarations are global library facts and therefore receive no per-extension or
  per-mutator options.
  """
  @callback macro_routes() :: [tuple() | Mutare.Macro.Spec.t()]

  @doc """
  Classify the visible arguments of a concrete macro registered with the `:routing` sentinel.

  A static per-position treatment list cannot express routing that depends on the call's shape —
  `where(q, category: "Foo")` is plain data while `where(q, [u], u.x == u.y)` contains a DSL
  fragment. Return one routing treatment per visible argument.

  The list covers only the call's **visible** arguments. For a piped call (`q |> where(c)`), the
  piped value is the `|>` LHS, not a visible argument, and stays an ordinary `:expression`. A
  classifier matching on arity must therefore match the visible arguments, not a fixed written
  arity. Returned treatments are validated by the transform: an unrecognised or mis-shaped
  treatment raises rather than silently mutating a position intended to be skipped or hosted.

  ## Per-keyword-pair routing — `{:keyword, value_treatments}`

  Besides the static treatments, a classifier may return two classifier-only values:

    * `{:keyword, value_treatments}` for a keyword-list argument. Core routes each pair's value by
      the corresponding positional treatment (values past the list default to `:skip`) and leaves
      every key raw, because a DSL keyword key is a field or option name, not a value. A value
      treatment may itself be `{:keyword, ...}`, so nested keyword lists route recursively. A
      non-keyword argument under this treatment is left raw. A nested `:hosted` value is delivered
      through `c:Mutare.Mutator.MacroHost.host/2`, which still receives the whole macro node.

    * `:pinned` for a scalar value in a compile-time DSL position that accepts interpolation but
      not a bare selector `case`. Core applies its configured literal families, records their own
      mutator names, and wraps the selector in `^`. Use it only where the macro genuinely accepts
      interpolation and only for a scalar value: mutations inside a compound value cannot be
      pinned at the correct depth and are rejected rather than allowed to poison the build.

  Returning `:hosted` leaves that position raw for core and delivers it through
  `c:Mutare.Mutator.MacroHost.host/2`. Only an enabled mutator implementing that capability may
  return `:hosted`.

  The motivating keyword case is `where(q, category: "Foo", deleted_at: nil)`, classified as
  `{:keyword, [:pinned, :skip]}`: mutate `"Foo"` through a pinned selector, keep the column-name
  keys raw, and skip the `nil` pair whose DSL meaning may be `IS NULL` rather than an Elixir value.
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
