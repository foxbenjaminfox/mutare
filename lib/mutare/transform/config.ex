defmodule Mutare.Transform.Config do
  @moduledoc false

  # The **immutable** half of a transform pass's threading context: everything fixed once,
  # at the top of `Mutare.Transform.plan_and_emit/2`, and read (never rewritten) by every
  # later stage. Two roles share this struct because they share that lifetime:
  #
  #   * pass configuration — the recorded `file`, the resolved `mutators`, and the
  #     poison-recovery `skip_ids` to drop;
  #   * generated-name hygiene — the private-function `prefix` and the four salted variable
  #     names the lifting/selector machinery emits (`active_var`/`super_var`/`piped_var`/
  #     `cond_var`). `Mutare.Transform.Names` derives each from a scan of the source's own
  #     identifiers, so a generated name can never collide with one in scope.
  #
  # Split out of the old monolithic `Ctx` so the *mutable* scope/claim state lives elsewhere
  # (`Mutare.Transform.{Scope,ClaimState}`); a stage reading config can't accidentally write
  # it, and the count pass shares it untouched.

  @type t :: %__MODULE__{
          file: String.t(),
          mutators: [Mutare.Mutator.Spec.t()],
          skip_ids: MapSet.t(),
          render_site_code: boolean(),
          summarize_sites: boolean(),
          prefix: String.t(),
          active_var: atom(),
          super_var: atom(),
          piped_var: atom(),
          cond_var: atom()
        }

  defstruct file: "nofile",
            mutators: [],
            skip_ids: MapSet.new(),
            # Whether each `Mutare.Site` records its rendered before/after diff text at build time
            # (`true`, the default), or defers it (`false`). Deferral is the scan's optimisation:
            # rendering a `Sourceror` diff per mutant dominates the build, yet only the handful of
            # sites a reporter actually shows need it, so a `mix mutare` run scans with this `false`
            # and re-derives the displayed sites' code at report time (`Mutare.Runner.Hydrate`).
            # It changes **no** id, tree, or count — only whether `Site.original_code`/`mutated_code`
            # are populated now or `nil` for later. `transform_string/2` defaults it `true`, so the
            # public API and tests are unaffected.
            render_site_code: true,
            # Whether each `Mutare.Site` records the cheap `Macro`-rendered live `summary` one-liner
            # (`true`), or leaves it `nil` (`false`, the default). Orthogonal to `render_site_code`:
            # the summary feeds the live in-flight activity line, which a deferred scan still shows,
            # so a `mix mutare` run sets this `true` unless `--quiet` (no live block). Off by default
            # so `transform_string/2`, the count pass, and tests build no summary. See
            # `Mutare.Site`'s "Live summary" section.
            summarize_sites: false,
            # The prefix for generated private (lifted) names. `"__mutare_"` is the canonical
            # value; `Mutare.Transform` recomputes it per file — scanning the source's own
            # definitions — to a collision-free variant when the target already defines a
            # `__mutare_`-prefixed name. `Mutare.Transform.Names` is the authority; this default
            # is just a safe, non-nil fallback.
            prefix: "__mutare_",
            # The variable a dispatcher/selector binds the active mutant id to (and the lifted
            # clauses' extra arg / guards read). `:mutare_active` canonically; salted per file
            # when the source already uses that identifier, so a generated guard can't capture a
            # user's variable.
            active_var: :mutare_active,
            # The variable a dispatcher binds the super-forwarding closure to when a lifted body
            # calls `super` (`Mutare.Transform.Super`). `:mutare_super` canonically; salted per
            # file like `active_var` so a `super(...)` rewritten to `<super_var>.(...)` can't
            # capture a user's variable of that name.
            super_var: :mutare_super,
            # The closure parameter a hoisted pipe stage binds the piped value to
            # (`Mutare.Transform.PipeEmit.hoist/2`). `:mutare_piped` canonically; salted per file
            # like `active_var` so a stage argument that mentions a same-named source variable
            # isn't captured by the closure param.
            piped_var: :mutare_piped,
            # The temp a refutable `if`/`unless` condition-hoist binds the match value to
            # (`Mutare.Transform.Analyze`'s condition hoisting). `:mutare_cond` canonically;
            # salted per file like `active_var`. Emit substitutes it for the placeholder the
            # (id-free) analyze pass leaves behind.
            cond_var: :mutare_cond
end
