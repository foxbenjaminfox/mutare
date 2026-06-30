defmodule Mutare.MacroRouting do
  @moduledoc """
  Behaviour for describing how Mutare should handle macro arguments.

  A macro can place an argument in a pattern or compile-time DSL position where Mutare's
  ordinary runtime descent would be invalid. A module implementing this behaviour registers
  those macros through `c:macro_routes/0`. A route may be static, or use the `:routing` sentinel
  to defer a concrete call's argument treatments to `c:macro_routing/2`.

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
        def macro_routing(call, _context), do: ...
      end

  Static routes may use `:expression`, `:pattern`, `:binding_pattern`, `:skip`, or `:hosted`.
  Shape-dependent routes use `:routing`. A `:hosted` treatment (static, or returned by
  `c:macro_routing/2`) additionally requires the contributing module to be an enabled mutator
  implementing `Mutare.Mutator.MacroHost`; routing extensions can classify arguments dynamically,
  but cannot host mutations because they do not produce mutations.

  ## Which behaviours do I implement?

  Routing and selector *delivery* are separate capabilities, so you declare only the ones you use:

  | Goal | Behaviours | Callbacks |
  | --- | --- | --- |
  | Library-vocabulary routing, no mutations (a `:extensions` entry) | `Mutare.MacroRouting` | `macro_routes/0` (+ `macro_routing/2` if any route is `:routing`) |
  | A mutator whose mutation depends on routing | `Mutare.Mutator` + `Mutare.MacroRouting` | `name/0`, a producer, `macro_routes/0` (+ `macro_routing/2`) |
  | A mutator that mutates *inside* a DSL fragment (`:hosted`) | `Mutare.Mutator` + `Mutare.MacroRouting` + `Mutare.Mutator.MacroHost` | `name/0`, `macro_routes/0`, `host/2` (+ `macro_routing/2`); a hosting mutator's producer may be `host/2` itself — no `mutate/1` needed |

  **Always declare the `@behaviour`s you implement.** The registry discovers capabilities by
  exported callbacks, so a typo'd or missing callback would otherwise compile to a silently inert
  module. Declaring `@behaviour` lets the compiler check the required callbacks, and the registry
  additionally rejects, at scan time, a module whose `macro_routing/2` or `host/2` no route ever
  reaches (a forgotten `:routing`/`:hosted` registration).

  See `Mutare.Macro.Spec` for entry forms, wildcards, and argument treatments.
  """

  @typedoc """
  A macro route entry returned by `c:macro_routes/0`: a `{module, name, arity, treatment}`
  4-tuple or a `{module, name, treatment}` 3-tuple (arity `:any`). `module`/`name`/`arity` may be
  the wildcard `:*`; `treatment` is a static `t:Mutare.Macro.Spec.args/0` or the `:routing`
  classifier sentinel. See `Mutare.Macro.Spec` for the forms and wildcard rules.
  """
  @type route :: tuple()

  @doc """
  Returns macro-route declarations.

  A treatment may be static or the `:routing` sentinel. `:routing` requires
  `c:macro_routing/2`; a static `:hosted` treatment requires
  `c:Mutare.Mutator.MacroHost.host/2` on an enabled mutator.

  Route declarations do not receive per-instance options.
  """
  @callback macro_routes() :: [route()]

  @doc """
  Returns one treatment for each visible argument of a registered macro call.

  Use this callback when routing depends on the call's shape. For a piped call, the
  pipe's left side is not a visible argument and is not included in the result.
  Returned treatments are validated.

  `context` is an opt-independent `t:routing_context/0` describing the call (currently its
  `:pipe_mode`); it carries no mutator options, because routing is a global library fact. Match it
  as a map (or `_context`) so a later field can't break your clause.

  The list covers only the call's **visible** arguments. For a piped call (`q |> where(c)`), the
  piped value is the `|>` LHS, not a visible argument, and stays an ordinary `:expression` —
  `context.pipe_mode` is `:piped` in that case, so a classifier matching on arity can tell the
  reduced shape from the written one. Returned treatments are validated by the transform: an
  unrecognised or mis-shaped treatment raises rather than silently mutating a position intended to
  be skipped or hosted. Prefer `Mutare.Transform.Calls.resolved_macro_call/1` to read the node
  rather than matching its raw head.

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
  @callback macro_routing(call_node :: Macro.t(), context :: routing_context()) :: [
              routing_treatment()
            ]

  @typedoc """
  The opt-independent context `c:macro_routing/2` receives for a concrete call. Currently carries
  the call's `:pipe_mode`; it may gain fields, so match it as a map rather than destructuring
  exhaustively. It deliberately carries **no** mutator options — routing is a global library fact.
  """
  @type routing_context :: %{pipe_mode: Mutare.Mutator.pipe_mode()}

  @typedoc """
  A treatment returned by `c:macro_routing/2` for one visible argument: a static
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

  @optional_callbacks macro_routing: 2
end
