defmodule Mutare.MacroRouting do
  @moduledoc """
  Behaviour for describing how Mutare should handle macro arguments.

  A macro can place an argument in a pattern or compile-time DSL position where Mutare's
  ordinary runtime descent would be invalid. A module implementing this behaviour registers
  those macros through `c:macro_routes/0`. A route may be static, or use the `:routing` sentinel
  to defer a concrete call's argument treatments to `c:route_arguments/2`.

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
        def route_arguments(call, _context) do
          routes = Enum.map(call.arguments, &classify/1)
          Mutare.MacroRouting.ArgumentRoutes.from_visible(call, routes)
        end
      end

  Shape-dependent routes use `:routing`. A `:hosted` treatment marks a position as raw for core
  and available to every enabled `Mutare.Mutator.MacroHost` subscribing to that macro. Routing and
  mutation ownership are independent: one library adapter can describe the DSL while several
  mutators contribute mutations inside it.

  ## Which behaviours do I implement?

  Routing and selector *delivery* are separate capabilities, so you declare only the ones you use:

  | Goal | Behaviours | Callbacks |
  | --- | --- | --- |
  | Library-vocabulary routing, no mutations (a `:extensions` entry) | `Mutare.MacroRouting` | `macro_routes/0` (+ `route_arguments/2` if any route is `:routing`) |
  | A mutator whose mutation depends on routing | `Mutare.Mutator` + `Mutare.MacroRouting` | `name/0`, a producer, `macro_routes/0` (+ `route_arguments/2`) |
  | A mutator that mutates *inside* a DSL fragment (`:hosted`) | `Mutare.Mutator` + `Mutare.Mutator.MacroHost` | `name/0`, `hosted_macros/0`, `host/2`; it may also implement `MacroRouting` when it owns the DSL's routes |

  **Always declare the `@behaviour`s you implement.** The registry discovers capabilities by
  exported callbacks, so a typo'd or missing callback would otherwise compile to a silently inert
  module. Declaring `@behaviour` lets the compiler check the required callbacks, and the registry
  additionally rejects, at scan time, a module whose `route_arguments/2` or `host/2` no route ever
  reaches (a forgotten `:routing`/`:hosted` registration).

  ## Route forms and precedence

  A route is `{module, name, arity, treatments}` or `{module, name, treatments}` for any arity.
  `:*` in the name position covers a whole module; `:*` in the module position is the last-resort
  name-only match for calls whose module cannot be resolved. Exact routes beat any-arity routes,
  which beat whole-module routes, which beat name-only routes.

  Identical declarations from multiple code providers coalesce. Conflicting code-provided routes
  raise `Mutare.MacroRouting.ContractError` instead of depending on configuration order. A
  declarative `:macro_routes` entry is an explicit final override.

  ## The committed surface

  An adapter should build against exactly these, and can expect compatibility from them:

    * this behaviour's callbacks and `Mutare.Mutator.MacroHost`'s;
    * `Mutare.MacroRouting.Call` — fields may be *added*, so match only the ones you need;
    * `Mutare.MacroRouting.ArgumentRoutes`, built through its constructors and read through its
      accessors (the struct itself is opaque);
    * `Mutare.Mutator.MacroHost.Target.new/4`;
    * the `Mutare.Transform.Calls` readers (`Mutare.Transform.Calls.resolved_call/1`,
      `Mutare.Transform.Calls.resolved_macro_call/1`, `Mutare.Transform.Calls.macro_treatment/1`);
    * `Mutare.MacroRouting.ContractError` as the failure type for provider conflicts and callback
      contract violations — its structured fields are stable; its message strings may improve at
      any time.

  Everything else in the routing path — the registry and its entries, the normalized route spec,
  transform metadata keys, candidate structs, and how selectors are assembled and nested — is
  internal and free to change between releases.
  """

  @typedoc """
  A macro route entry returned by `c:macro_routes/0`: a `{module, name, arity, treatment}`
  4-tuple or a `{module, name, treatment}` 3-tuple (arity `:any`). `module`/`name`/`arity` may be
  the wildcard `:*`; `treatment` is a static `t:treatment/0`, a list of treatments, or the
  `:routing` classifier sentinel.
  """
  @type route_module :: atom()
  @type route_name :: atom()
  @type route_arity :: non_neg_integer() | :any | :*
  @type route_args :: treatment() | [treatment()] | :routing
  @type route ::
          {route_module(), route_name(), route_args()}
          | {route_module(), route_name(), route_arity(), route_args()}

  @doc """
  Returns macro-route declarations.

  A treatment may be static or the `:routing` sentinel. `:routing` requires
  `c:route_arguments/2`. A `:hosted` treatment requires at least one enabled
  `Mutare.Mutator.MacroHost` whose `c:Mutare.Mutator.MacroHost.hosted_macros/0` matches it.

  Route declarations do not receive per-instance options.
  """
  @callback macro_routes() :: [route()]

  @doc """
  Classify a concrete macro registered with the `:routing` sentinel.

  A static per-position treatment list cannot express routing that depends on the call's shape —
  `where(q, category: "Foo")` is plain data while `where(q, [u], u.x == u.y)` contains a DSL
  fragment. Return a `Mutare.MacroRouting.ArgumentRoutes` value.

  `context` is an opt-independent `t:routing_context/0` describing the call (currently its
  `:pipe_mode`); it carries no mutator options, because routing is a global library fact. Match it
  as a map (or `_context`) so a later field can't break your clause.

  The `call` is a stable `Mutare.MacroRouting.Call`, already normalized across bare, qualified,
  aliased, imported, and piped forms. `ArgumentRoutes.from_effective/2` uses the same effective
  argument order as static declarations. `ArgumentRoutes.from_visible/3` is convenient when only
  written arguments matter and makes the pipe-left treatment explicit. Returned treatments and
  lengths are validated by the transform.

    * `{:keyword, treatments}` — routes keyword values positionally while leaving
      keys unchanged; extra values default to `:skip`, and nested keyword routing is
      supported
    * `:pinned` — applies configured literal mutations to a scalar DSL value and
      wraps the selector in `^`; use only where the macro accepts interpolation
    * `:hosted` — delegates the position to
      `c:Mutare.Mutator.MacroHost.host/2`; only an enabled hosting mutator may return
      it

  Static and dynamic routes share one recursive treatment vocabulary:

    * `{:keyword, value_treatments}` for a keyword-list argument. Core routes each pair's value by
      the corresponding positional treatment (values past the list default to `:skip`) and leaves
      every key raw, because a DSL keyword key is a field or option name, not a value. A value
      treatment may itself be `{:keyword, ...}`, so nested keyword lists route recursively. A
      non-keyword argument under this treatment is left raw. A nested `:hosted` value is delivered
      through `c:Mutare.Mutator.MacroHost.host/2`, which receives the resolved whole macro call.

    * `:pinned` for a scalar value in a compile-time DSL position that accepts interpolation but
      not a bare selector `case`. Core applies its configured literal families, records their own
      mutator names, and wraps the selector in `^`. Use it only where the macro genuinely accepts
      interpolation and only for a scalar value: mutations inside a compound value cannot be
      pinned at the correct depth and are rejected rather than allowed to poison the build.

  Returning `:hosted` leaves that position raw for core and offers the call to every subscribed
  host mutator.

  The motivating keyword case is `where(q, category: "Foo", deleted_at: nil)`, classified as
  `{:keyword, [:pinned, :skip]}`: mutate `"Foo"` through a pinned selector, keep the column-name
  keys raw, and skip the `nil` pair whose DSL meaning may be `IS NULL` rather than an Elixir value.
  """
  @callback route_arguments(call :: Mutare.MacroRouting.Call.t(), context :: routing_context()) ::
              Mutare.MacroRouting.ArgumentRoutes.t()

  @typedoc """
  The opt-independent context `c:route_arguments/2` receives for a concrete call. Currently carries
  the call's `:pipe_mode`; it may gain fields, so match it as a map rather than destructuring
  exhaustively. It deliberately carries **no** mutator options — routing is a global library fact.
  """
  @type routing_context :: %{pipe_mode: Mutare.Mutator.pipe_mode()}

  @typedoc """
  A treatment for one macro argument or nested keyword value.
  """
  @type treatment ::
          :expression
          | :pattern
          | :binding_pattern
          | :skip
          | :hosted
          | :pinned
          | {:keyword, [treatment()]}

  @type routing_treatment :: treatment()
  @type keyword_value_treatment :: treatment()

  @optional_callbacks route_arguments: 2
end
