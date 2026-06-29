defmodule Mutare.MacroRouting do
  @moduledoc """
  Capability behaviour for controlling macro-argument routing.

  A macro can place an argument in a pattern or compile-time DSL position where Mutare's
  ordinary runtime descent would be invalid. A module implementing this behaviour registers
  those macros through `c:macro_routes/0`. A route may be static, or use the `:routing` sentinel
  to defer a concrete call's argument treatments to `c:macro_routing/1`.

  The capability is deliberately independent of how the module is enabled:

    * a non-mutating module listed under `:extensions` may implement it alongside
      `Mutare.UseExpansion`;
    * a `Mutare.Mutator` may implement it when its mutation depends on macro routing.

  Enabled mutators and extensions are inspected automatically, so either form still needs only
  one configuration entry.

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

  Static routes may use `:expression`, `:pattern`, `:binding_pattern`, `:skip`, or `:hosted`.
  Shape-dependent routes use `:routing`. A `:hosted` treatment additionally requires the
  contributing module to be an enabled mutator implementing `Mutare.Mutator.MacroHost`; routing
  extensions can classify arguments dynamically, but cannot host mutations because they do not
  produce mutations.

  See `Mutare.Macro.Spec` for entry forms, wildcards, and argument treatments.
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
