defmodule Mutare.CallRouting do
  @moduledoc """
  Behaviour for describing how Mutare should treat particular calls.

  A **call route** names a resolved `{module, function, arity}` — a macro or a plain function,
  with the same lookup rules for both — and specifies one of two treatments:

    * **skip the whole call** (`:skip`): the call is an inert leaf. Nothing inside its parentheses
      is descended and the call node itself is never offered to a mutator. A piped receiver is the
      `|>`'s other operand, so it is analyzed as usual — except where the skip displaced a route
      that governs position 0, whose treatment the receiver keeps, since skipping a call must never
      free a position the displaced route held (skip `Kernel.match?/2` and `1 |> match?(x)`'s
      receiver stays the pattern it is). A skipped call in
      tail position still gets the enclosing function's return-value mutants. The word for "this
      call is not worth testing" (`Mixpanel.track/3`, a logger, a metrics emitter). It applies to
      whatever the head resolves to — a function, a macro such as `Kernel.if/2`, or a special form
      (`{Kernel.SpecialForms, :case, :skip}`; special-form arities follow the AST, so use the
      any-arity form).
    * **treat each argument** by a *position*: `:expression` (ordinary runtime code, the default),
      `:lazy_expression` (the same, for a callee that may evaluate the argument late,
      conditionally, more than once, or never — see "Evaluation" below), `:raw` (leave the argument exactly as written — a DSL body, a pattern interpreted by the macro, an
      identifier list), `:interior` (descend into the argument but offer nothing on its own node —
      an assigns map whose emptying is a crash-kill while its values are the signal), `:pattern` /
      `:binding_pattern` (descend as a match pattern), and — for a literal keyword-list argument — a
      **keyed refinement** `[leading, key: position, …]` that routes one named option's value by its
      own position (`[:expression, timeout: :raw]`; the leading treatment defaults to `:expression`,
      pairs may nest).

  Users write routes under `call_routes:` in `.mutare.exs`; a module implementing this behaviour
  registers them through `c:call_routes/0`. A route may be static, or use the `:routing` sentinel to
  defer a concrete call's argument treatments to `c:route_arguments/1`.

  Both extensions and mutators may implement this behaviour. Enabling the module under `:extensions`
  or `:mutators` also enables its routes.

  A piped first argument is a first argument. Mutare treats a piped call as the direct call
  `Kernel.|>/2` would build, so a route, a classifier, a host and a mutator all see
  `from(p in Post, …)` for `(p in Post) |> from(…)`, and a `:raw` declaration reaches the macro
  as the syntax it is. (The exception is a call routed `:skip`: a value piped *into* it is not
  part of the skipped call, and still mutates.) Reports keep the pipe the user wrote, and
  so does any code Mutare leaves alone: a pipe inside a `:raw` argument or a `:skip`ped call is
  never rewritten.

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
        def route_arguments(call) do
          routes = Enum.map(call.arguments, &classify/1)
          Mutare.CallRouting.ArgumentRoutes.new(call, routes)
        end
      end

  Shape-dependent routes use `:routing`. A `:hosted` treatment marks a position as raw for core and available to every enabled `Mutare.Mutator.MacroHost` subscribing to that macro. Routing and mutation ownership are independent: one library adapter can describe the DSL while several mutators contribute mutations inside it.

  ## Ordinary calls

  **A call is ordinary in every respect its route does not address.** Ordinary is how a plain
  function call behaves: each argument is a runtime expression, evaluated once, ahead of the
  call and in order; the call binds nothing its caller can see; and the call itself is a value
  a mutant may replace. Mutare treats every call that way — unrouted, or routed for some other
  reason (a call routed `[:raw, :expression]` to hold one argument back is ordinary
  everywhere else) — and it never works out whether the callee is a function or a macro in
  order to decide. Most macros are ordinary in this sense (`assert`, a logging wrapper) and
  need no route. One that is not says *how*, with the word for it: a position it reads as a
  pattern is `:pattern`, one it reads as syntax is `:raw`, one it may never evaluate is
  `:lazy_expression`. A mutant placed where a macro cannot accept it fails the metamutant's
  compile and is recovered as poison: dropped, and reported `:poisoned`. Where Mutare cannot
  tell which mutant to drop, the run stops and prints the route to add.

  ## Evaluation

  Ordinary includes *when a call's arguments run*, and to deliver a whole-call mutant on a pipe
  stage Mutare relies on it, evaluating the piped value once and handing every branch the
  result. It does so whenever the stage's first position is `:expression` or `:interior`,
  routed or not. (A mutant that itself moves or replaces that argument evaluates its own
  expression, in its own order.)

  A macro need not evaluate its arguments that way (`value |> lazy(enabled?)` may expand to
  `if enabled?, do: value`), and nothing in `:expression` says it does. Route such a position
  `:lazy_expression`: Mutare mutates the argument exactly as it would an `:expression`, and
  never evaluates it ahead of the call — every branch hands the callee the expression itself.
  A position routed as syntax (`:raw`, a pattern, `:hosted`, …) is never evaluated ahead either.
  `:lazy_expression` can only switch that optimisation off, so it is safe to declare wherever
  you are unsure; the price is a larger metamutant for long chains of such stages.

  ## The vocabulary, tiered

  `:skip`, `:raw`, `:interior`, `:expression`, `:lazy_expression`, `:pattern`, `:binding_pattern`, and keyed refinements built from them can only *remove* or *re-route* mutants, and preserve those declared argument contexts; they are the whole vocabulary the declarative `call_routes:` configuration key accepts. `:interpolated`, `{:keyword, ...}`, and `:hosted` are adapter-grade: each asserts a fact about a DSL that Mutare cannot verify, and the module routing it takes responsibility for that fact. An `:interpolated` position must genuinely accept `^` interpolation — where it doesn't, the spliced selector fails the single metamutant compile and is recovered as poison, discarding those mutants after a rebuild. A `{:keyword, ...}` list routes keyword *values positionally* and must name exactly one treatment per pair — a length mismatch raises at transform time, and a non-keyword argument under it is left raw (warned when a `:routing` classifier routed it; silent for a static route, whose other call shapes may be legal forms). A `:hosted` route without an enabled subscribing host aborts the run at scan time. These treatments must come from a module implementing this behaviour — an adapter written and tested against the library it describes; a declarative `call_routes:` entry that uses one (a keyed refinement included) is rejected with an `ArgumentError`.

  `:skip` is a statement about the *call*, so it is valid only as a route's bare treatment (`{Mixpanel, :track, 3, :skip}`); inside a per-position list it is rejected with a message naming `:raw`. Every other word is a statement about a *position*.

  **Structural heads.** The forms Mutare analyzes structurally rather than as calls — `if`/`unless`, `|>`, the boolean connectives (`and`/`or`/`&&`/`||`) and negations (`!`/`not`), `in`, and the construct special forms (`case`, `cond`, `with`, `for`, `try`, `receive`, `fn`, `quote`, `&`) — have no argument positions in the routing sense: a route on one accepts only `:skip`. An explicit positional route (`{Kernel, :if, 2, [:raw, :expression]}`) is rejected with an `ArgumentError`; a wildcard route's positions (`{Kernel, :*, :raw}`) simply do not apply to them. These are the `Kernel` forms only: a `|>` that a module displaced (`import Kernel, except: [|>: 2]` beside its own operator) is an ordinary call to that operator — unrouted, both operands are values — and takes any positional route. A pipe-shaped *macro* reads its right side as the syntax of a call still missing an argument, so route it `{MyPipe, :|>, 2, [:expression, :interior]}`: the stage's own node is withheld, its arguments still mutate. Definitions and directives (`def`/`defp`, `defmacro`/`defmacrop`, `defmodule`, `defimpl`/`defprotocol`/`defdelegate`, `use`, `@`) are not calls a route can act on at all — nor are the directives (`alias`/`import`/`require`), the compiler-internal forms (`__block__`, `__aliases__`, `.`), or the literal and pattern forms (`{}`, `%{}`, `%`, `<<>>`, `=`, `^`, `::`), whose mutations are handled by the literal families (`--mutators`, `# mutare:ignore[<family>]`). `# mutare:ignore` is the tool for leaving a definition alone, and `# mutare:ignore[conditional]` (or `--mutators`) for holding back particular mutants inside an `if`.

  Routes are positional and transform-enforced: no mutator is consulted. The other facility for leaving something alone — **argument marks** (`argument_marks:` / `c:Mutare.Mutator.argument_marks/1`) — labels a position for value-dependent handling by each mutator. The built-in timeout exclusions use these marks to skip duration literals while allowing mutations in computed durations. Reach for a route when the position should simply not mutate; reach for a mark when the reaction should depend on the value. See `Mutare.Mutator`.

  ## Which behaviours do I implement?

  Routing and selector *delivery* are separate capabilities, so you declare only the ones you use:

  | Goal | Behaviours | Callbacks |
  | --- | --- | --- |
  | Library-vocabulary routing, no mutations (a `:extensions` entry) | `Mutare.CallRouting` | `call_routes/0` (+ `route_arguments/1` if any route is `:routing`) |
  | A mutator whose mutation depends on routing | `Mutare.Mutator` + `Mutare.CallRouting` | `name/0`, a producer, `call_routes/0` (+ `route_arguments/1`) |
  | A mutator that mutates *inside* a DSL fragment (`:hosted`) | `Mutare.Mutator` + `Mutare.Mutator.MacroHost` | `name/0`, `hosted_macros/0`, `host/2`; it may also implement `CallRouting` when it also defines the DSL's routes |

  Always declare the `@behaviour`s you implement. The registry discovers capabilities by exported callbacks, so a typo'd or missing callback would otherwise compile to a silently inert module. Declaring `@behaviour` lets the compiler check the required callbacks, and the registry additionally rejects, at scan time, a module whose `route_arguments/1` or `host/2` no route ever reaches (a forgotten `:routing`/`:hosted` registration).

  ## Route forms and precedence

  A route is `{module, name, arity, treatments}` or `{module, name, treatments}` for any arity, where `treatments` is `:skip`, one position for every argument, or a per-position list (padded with `:expression`). `:*` in the name position covers a whole module; `:*` in the module position is the last-resort name-only match for calls whose module cannot be resolved. Exact routes beat any-arity routes, which beat whole-module routes, which beat name-only routes — so `{Mixpanel, :*, :skip}` plus `{Mixpanel, :track, 3, [:expression, :raw, :raw]}` skips every Mixpanel call except `track/3`, which mutates its first argument.

  Identical declarations from multiple code providers coalesce. Conflicting code-provided routes raise `Mutare.CallRouting.ContractError` instead of depending on configuration order. A declarative `call_routes:` entry is an explicit final override for its key, restricted to the user-tier vocabulary above; a configured `:skip` that displaces an adapter's hosted route is honoured (the user turned the call off), not reported as the adapter's contract violation. The `--skip-call Module.fun/arity` flag is the CLI spelling of a `:skip` entry.

  Mutare matches module-specific routes against remote calls (including aliases) and imports it
  can resolve, with or without a pipe, through the same resolution the call-matching mutator
  families use.

  **Local-call limitation.** Mutare does not resolve an unqualified call to a function defined in
  the calling module to that module. Thus `{SomeModule, :foobar, 0, :skip}` does not skip
  `foobar()` inside `SomeModule`. It does skip `SomeModule.foobar()`, whether called inside or
  outside `SomeModule`, and `foobar()` in another module that imports `SomeModule` when Mutare
  can resolve the import. This limitation applies to module-specific routes regardless of their
  treatment.

  A module wildcard bypasses that limitation: `{:*, :foobar, 0, :skip}` matches by name and arity,
  including local `foobar()` calls inside modules that define `foobar/0`. It applies across
  modules, subject to the precedence of more specific routes above.

  A configured route (or mark) that matched no call anywhere in a full scan is reported as a
  warning, so a typo'd module or a wrong arity never sits silently inert.

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
  `c:route_arguments/1`. A `:hosted` treatment requires at least one enabled
  `Mutare.Mutator.MacroHost` whose `c:Mutare.Mutator.MacroHost.hosted_macros/0` matches it.

  Route declarations do not receive per-instance options.
  """
  @callback call_routes() :: [route()]

  @doc """
  Classify a concrete call registered with the `:routing` sentinel.

  A static per-position treatment list cannot express routing that depends on the call's shape —
  `where(q, category: "Foo")` is plain data while `where(q, [u], u.x == u.y)` contains a DSL
  fragment. Return a `Mutare.CallRouting.ArgumentRoutes` value.

  The callback receives the call and nothing else — no mutator options, because routing is a
  global library fact.

  The `call` is a stable `Mutare.CallRouting.Call`, already normalized across bare, qualified,
  aliased, imported, and piped forms: a piped call arrives as the direct call, its piped operand
  as argument 0, so that position is routed by its shape like any other (`Post |> from(…)` and
  `build(x) |> from(…)` need not share a treatment). What sits *inside* the arguments
  is as the user wrote it, here and in `host/2` and `mutate/2` alike: an upstream stage in
  argument 0 is still a `|>` node, which `Mutare.Calls.resolved_routed_call/1` reads as its
  direct call when you need to look into it. One difference remains between the seams: a
  classifier's arguments are not yet resolved (`Mutare.Calls.resolved_call/1` returns `nil`
  inside them), a host's and a mutator's are. Return `ArgumentRoutes.new(call, treatments)`, one treatment
  per argument, in the order a static declaration uses. Returned treatments and lengths are
  validated by the transform.

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
  @callback route_arguments(call :: Mutare.CallRouting.Call.t()) ::
              Mutare.CallRouting.ArgumentRoutes.t()

  @typedoc """
  A treatment for one call argument or nested keyword value: an atom treatment, a `{:keyword, …}`
  per-pair routing, or a keyed refinement `[leading, key: treatment, …]` (a list whose optional
  first element is the leading treatment and whose remaining elements are `{key, treatment}` pairs).
  The call-level `:skip` is not a treatment — see `t:route_args/0`.
  """
  @type treatment ::
          :expression
          | :lazy_expression
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

  @optional_callbacks route_arguments: 1
end
