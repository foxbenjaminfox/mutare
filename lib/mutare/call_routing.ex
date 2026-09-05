defmodule Mutare.CallRouting do
  @moduledoc """
  Behaviour for describing how Mutare should treat particular calls.

  A **call route** names a resolved `{module, function, arity}` — a macro or a plain function; the
  registry keys on the resolved call and never asks which — and says one of two kinds of thing
  about it:

    * **skip the whole call** (`:skip`): the call is an inert leaf. Nothing inside its parentheses
      is descended and the call node itself is never offered to a mutator. A piped receiver is the
      `|>`'s other operand, not part of the call, so it is analyzed as usual; a skipped call in
      tail position still gets the enclosing function's return-value mutants. The word for "this
      call is not worth testing" (`Mixpanel.track/3`, a logger, a metrics emitter). It applies to
      whatever the head resolves to — a function, a macro such as `Kernel.if/2`, or a special form
      (`{Kernel.SpecialForms, :case, :skip}`; special-form arities follow the AST, so use the
      any-arity form).
    * **treat each argument** by a *position*: `:expression` (ordinary runtime code, the default),
      `:raw` (leave the argument exactly as written — a DSL body, a pattern the macro owns, an
      identifier list), `:interior` (descend into the argument but offer nothing on its own node —
      an assigns map whose emptying is a crash-kill while its values are the signal), `:pattern` /
      `:binding_pattern` (descend as a match pattern), and — for a literal keyword-list argument — a
      **keyed refinement** `[leading, key: position, …]` that routes one named option's value by its
      own position (`[:expression, timeout: :raw]`; the leading treatment defaults to `:expression`,
      pairs may nest).

  Users write routes under `call_routes:` in `.mutare.exs`; a module implementing this behaviour
  registers them through `c:call_routes/0`. A route may be static, or use the `:routing` sentinel to
  defer a concrete call's argument treatments to `c:route_arguments/2`.

  Both extensions and mutators may implement this behaviour. Enabling the module under `:extensions`
  or `:mutators` also enables its routes.

      defmodule MyApp.EctoRouting do
        @behaviour Mutare.CallRouting

        @impl Mutare.CallRouting
        def call_routes do
          [
            {Ecto.Query, :where, :any, :routing},
            {Ecto.Query, :from, 2, [:expression, :raw]}
          ]
        end

        @impl Mutare.CallRouting
        def route_arguments(call, _context) do
          routes = Enum.map(call.arguments, &classify/1)
          Mutare.CallRouting.ArgumentRoutes.from_visible(call, routes)
        end
      end

  Shape-dependent routes use `:routing`. A `:hosted` treatment marks a position as raw for core and available to every enabled `Mutare.Mutator.MacroHost` subscribing to that macro. Routing and mutation ownership are independent: one library adapter can describe the DSL while several mutators contribute mutations inside it.

  ## The vocabulary, tiered

  `:skip`, `:raw`, `:interior`, `:expression`, `:pattern`, `:binding_pattern`, and keyed refinements built from them can only *remove* or *re-route* mutants, so they can never break the single metamutant compile; they are the whole vocabulary the declarative `call_routes:` configuration key accepts. `:interpolated`, `{:keyword, ...}`, and `:hosted` are adapter-grade: each asserts a fact about a DSL that Mutare cannot verify, and the module routing it takes responsibility for that fact. An `:interpolated` position must genuinely accept `^` interpolation — where it doesn't, the spliced selector fails the single metamutant compile and is recovered as poison, discarding those mutants after a rebuild. A `{:keyword, ...}` list routes keyword *values positionally* and must name exactly one treatment per pair — a length mismatch raises at transform time, and a non-keyword argument under it is left raw (warned when a `:routing` classifier routed it; silent for a static route, whose other call shapes may be legal forms). A `:hosted` route without an enabled subscribing host aborts the run at scan time. These treatments must come from a module implementing this behaviour — an adapter written and tested against the library it describes; a declarative `call_routes:` entry that uses one (a keyed refinement included) is rejected with an `ArgumentError`.

  `:skip` is a statement about the *call*, so it is valid only as a route's bare treatment (`{Mixpanel, :track, 3, :skip}`); inside a per-position list it is rejected with a message naming `:raw`. Every other word is a statement about a *position*.

  **Structural heads.** The forms Mutare analyzes structurally rather than as calls — `if`/`unless`, `|>`, the boolean connectives (`and`/`or`/`&&`/`||`) and negations (`!`/`not`), `in`, and the construct special forms (`case`, `cond`, `with`, `for`, `try`, `receive`, `fn`, `quote`, `&`) — have no argument positions in the routing sense: a route on one accepts only `:skip`. An explicit positional route (`{Kernel, :if, 2, [:raw, :expression]}`) is rejected with an `ArgumentError`; a wildcard route's positions (`{Kernel, :*, :raw}`) simply do not apply to them. Definitions and directives (`def`/`defp`, `defmacro`/`defmacrop`, `defmodule`, `defimpl`/`defprotocol`/`defdelegate`, `use`, `@`) are not calls a route can act on at all — nor are the directives (`alias`/`import`/`require`), the compiler-internal forms (`__block__`, `__aliases__`, `.`), or the literal and pattern forms (`{}`, `%{}`, `%`, `<<>>`, `=`, `^`, `::`), which are data syntax the literal families own (`--mutators`, `# mutare:ignore[<family>]`). `# mutare:ignore` is the tool for leaving a definition alone, and `# mutare:ignore[conditional]` (or `--mutators`) for holding back particular mutants inside an `if`.

  Routes are positional and transform-enforced: no mutator is consulted. The other facility for leaving something alone — **argument marks** (`argument_marks:` / `c:Mutare.Mutator.argument_marks/1`) — labels a position and lets each mutator decide what the label means, which is how the built-in timeout table declines a duration literal but not a computed one. Reach for a route when the position should simply not mutate; reach for a mark when the reaction should depend on the value. See `Mutare.Mutator`.

  ## Which behaviours do I implement?

  Routing and selector *delivery* are separate capabilities, so you declare only the ones you use:

  | Goal | Behaviours | Callbacks |
  | --- | --- | --- |
  | Library-vocabulary routing, no mutations (a `:extensions` entry) | `Mutare.CallRouting` | `call_routes/0` (+ `route_arguments/2` if any route is `:routing`) |
  | A mutator whose mutation depends on routing | `Mutare.Mutator` + `Mutare.CallRouting` | `name/0`, a producer, `call_routes/0` (+ `route_arguments/2`) |
  | A mutator that mutates *inside* a DSL fragment (`:hosted`) | `Mutare.Mutator` + `Mutare.Mutator.MacroHost` | `name/0`, `hosted_macros/0`, `host/2`; it may also implement `CallRouting` when it owns the DSL's routes |

  Always declare the `@behaviour`s you implement. The registry discovers capabilities by exported callbacks, so a typo'd or missing callback would otherwise compile to a silently inert module. Declaring `@behaviour` lets the compiler check the required callbacks, and the registry additionally rejects, at scan time, a module whose `route_arguments/2` or `host/2` no route ever reaches (a forgotten `:routing`/`:hosted` registration).

  ## Route forms and precedence

  A route is `{module, name, arity, treatments}` or `{module, name, treatments}` for any arity, where `treatments` is `:skip`, one position for every argument, or a per-position list (padded with `:expression`). `:*` in the name position covers a whole module; `:*` in the module position is the last-resort name-only match for calls whose module cannot be resolved. Exact routes beat any-arity routes, which beat whole-module routes, which beat name-only routes — so `{Mixpanel, :*, :skip}` plus `{Mixpanel, :track, 3, [:expression, :raw, :raw]}` skips every Mixpanel call except `track/3`, which mutates its first argument.

  Identical declarations from multiple code providers coalesce. Conflicting code-provided routes raise `Mutare.CallRouting.ContractError` instead of depending on configuration order. A declarative `call_routes:` entry is an explicit final override for its key, restricted to the user-tier vocabulary above; a configured `:skip` that displaces an adapter's hosted route is honoured (the user turned the call off), not reported as the adapter's contract violation. The `--skip-call Module.fun/arity` flag is the CLI spelling of a `:skip` entry.

  Mutare matches a route however the call is written — qualified, aliased, imported, or piped — through the same resolution the call-matching mutator families use. A configured route (or mark) that matched no call anywhere in a full scan is reported as a warning, so a typo'd module or a wrong arity never sits silently inert.

  ## The committed surface

  An adapter should build against exactly these, and can expect compatibility from them:

    * this behaviour's callbacks and `Mutare.Mutator.MacroHost`'s;
    * `Mutare.CallRouting.Call` — fields may be *added*, so match only the ones you need;
    * `Mutare.CallRouting.ArgumentRoutes`, built through its constructors and read through its accessors (the struct itself is opaque);
    * `Mutare.Mutator.MacroHost.Target.new/4`;
    * the `Mutare.Calls` readers (`Mutare.Calls.resolved_call/1`, `Mutare.Calls.resolved_routed_call/1`, `Mutare.Calls.routed_treatments/1`);
    * `Mutare.CallRouting.ContractError` as the failure type for provider conflicts and callback contract violations — its structured fields are stable; its message strings may improve at any time.

  Everything else in the routing path — the registry and its entries, the normalized route spec, transform metadata keys, candidate structs, and how selectors are assembled and nested — is internal and free to change between releases.
  """

  @typedoc """
  A call route entry returned by `c:call_routes/0`: a `{module, name, arity, treatment}`
  4-tuple or a `{module, name, treatment}` 3-tuple (arity `:any`). `module`/`name`/`arity` may be
  the wildcard `:*`; `treatment` is the call-level `:skip`, a static `t:treatment/0`, a list of
  treatments, or the `:routing` classifier sentinel.
  """
  @type route_module :: atom()
  @type route_name :: atom()
  @type route_arity :: non_neg_integer() | :any | :*
  @type route_args :: :skip | treatment() | [treatment()] | :routing
  @type route ::
          {route_module(), route_name(), route_args()}
          | {route_module(), route_name(), route_arity(), route_args()}

  @doc """
  Returns call-route declarations.

  A treatment may be static or the `:routing` sentinel. `:routing` requires
  `c:route_arguments/2`. A `:hosted` treatment requires at least one enabled
  `Mutare.Mutator.MacroHost` whose `c:Mutare.Mutator.MacroHost.hosted_macros/0` matches it.

  Route declarations do not receive per-instance options.
  """
  @callback call_routes() :: [route()]

  @doc """
  Classify a concrete call registered with the `:routing` sentinel.

  A static per-position treatment list cannot express routing that depends on the call's shape —
  `where(q, category: "Foo")` is plain data while `where(q, [u], u.x == u.y)` contains a DSL
  fragment. Return a `Mutare.CallRouting.ArgumentRoutes` value.

  `context` is an opt-independent `t:routing_context/0` describing the call (currently its
  `:pipe_mode`); it carries no mutator options, because routing is a global library fact. Match it
  as a map (or `_context`) so a later field can't break your clause.

  The `call` is a stable `Mutare.CallRouting.Call`, already normalized across bare, qualified,
  aliased, imported, and piped forms. `ArgumentRoutes.from_effective/2` uses the same effective
  argument order as static declarations. `ArgumentRoutes.from_visible/3` is convenient when only
  written arguments matter and makes the pipe-left treatment explicit. Returned treatments and
  lengths are validated by the transform.

    * `{:keyword, treatments}` — routes keyword values positionally while leaving
      keys unchanged; the list must name exactly one treatment per pair, and nested
      keyword routing is supported
    * `:interpolated` — the value is interpolable data: core reuses its own
      mutators on it and delivers every mutation through `^` interpolation,
      introducing the pin for a bare scalar and descending inside an existing
      `^`; use only where the macro accepts interpolation
    * `:hosted` — delegates the position to
      `c:Mutare.Mutator.MacroHost.host/2`; only an enabled hosting mutator may return
      it

  Static and dynamic routes share one recursive treatment vocabulary (a classifier may return a
  keyed refinement `[leading, key: treatment, …]` exactly as a static route writes it):

    * `{:keyword, value_treatments}` for a keyword-list argument. Core routes each pair's value by
      the corresponding positional treatment and leaves every key raw, because a DSL keyword key
      is a field or option name, not a value. The list is strict — exactly one treatment per pair
      (`:raw` a value to leave it as written); a length mismatch at a concrete call raises, so a static
      keyword route fits only call sites with a fixed pair count (variable shapes belong to
      `:routing`). A value treatment may itself be `{:keyword, ...}`, so nested keyword lists route
      recursively. A non-keyword argument under this treatment is left raw — silently for a static
      route (a non-keyword call site is a legitimate alternate macro form, `set(q, opts)`), with a
      printed warning when a `:routing` classifier did it (the classifier saw the concrete
      argument, so the mismatch is a classifier bug). A nested `:hosted` value is delivered
      through `c:Mutare.Mutator.MacroHost.host/2`, which receives the resolved whole macro call.

    * `:interpolated` for a value in a compile-time DSL position that accepts interpolation but
      not a bare selector `case`. The name is the contract: the value is *interpolated data*, and
      core reuses its own mutators on it, delivering every mutation through the `^`. For a bare
      scalar (`category: "Foo"`) the configured literal families attach their ordinary mutations —
      each Site records the owning family's name (`:string`, `:integer`, …), never the adapter's —
      and the selector is emitted wrapped in `^`. Its limits, precisely:

      * **Bare values must be scalar.** A bare compound value (a list, map, or tuple) attaches
        mutations to *descendant* nodes that the `^` wrap cannot reach, so it is rejected at
        transform time with an `ArgumentError` rather than left to poison the build. Route a
        compound value `:raw`, or route a keyword list per-pair via `{:keyword, ...}`.
      * **An already-`^`-pinned value is descended, not re-pinned.** Past a `^` the source wrote
        itself, the code is plain Elixir evaluated at build time, where ordinary selectors are
        legal — core mutates it like any runtime expression, arbitrarily deep, and leaves the
        existing `^` alone. The scalar-only rule applies to bare values — the ones core must pin
        itself — so a static route stays sound on call sites that mix `category: "Foo"` with
        `total: ^(a + b)`.
      * **The DSL must genuinely accept `^` interpolation at that position.** Mutare cannot check
        this assertion; where it is wrong, the spliced `^(case …)` fails the single metamutant
        compile and is recovered as poison — those mutants are discarded after a rebuild.
      * **Only in-place mutations on a bare value's own node apply.** For a scalar literal that is
        core's literal families; a variable yields no mutants at all. (The guard is positional,
        not kind-based: a mutation whose node *is* the whole value — an operator swap on `a + b` —
        rides the same pin, sound in any DSL that accepted the bare expression to begin with.)

  Returning `:hosted` leaves that position raw for core and offers the call to every subscribed
  host mutator.

  The motivating keyword case is `where(q, category: "Foo", deleted_at: nil)`, classified as
  `{:keyword, [:interpolated, :raw]}`: mutate `"Foo"` through a `^`-pinned selector, keep the column-name
  keys raw, and skip the `nil` pair whose DSL meaning may be `IS NULL` rather than an Elixir value.
  """
  @callback route_arguments(call :: Mutare.CallRouting.Call.t(), context :: routing_context()) ::
              Mutare.CallRouting.ArgumentRoutes.t()

  @typedoc """
  The opt-independent context `c:route_arguments/2` receives for a concrete call. Currently carries
  the call's `:pipe_mode`; it may gain fields, so match it as a map rather than destructuring
  exhaustively. It deliberately carries **no** mutator options — routing is a global library fact.
  """
  @type routing_context :: %{pipe_mode: Mutare.Mutator.pipe_mode()}

  @typedoc """
  A treatment for one call argument or nested keyword value: an atom treatment, a `{:keyword, …}`
  per-pair routing, or a keyed refinement `[leading, key: treatment, …]` (a list whose optional
  first element is the leading treatment and whose remaining elements are `{key, treatment}` pairs).
  The call-level `:skip` is not a treatment — see `t:route_args/0`.
  """
  @type treatment ::
          :expression
          | :interior
          | :raw
          | :pattern
          | :binding_pattern
          | :hosted
          | :interpolated
          | {:keyword, [treatment()]}
          | [treatment() | {atom(), treatment()}]

  @type routing_treatment :: treatment()
  @type keyword_value_treatment :: treatment()

  @optional_callbacks route_arguments: 2
end
