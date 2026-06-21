defmodule Mutare.Transform.Ctx do
  @moduledoc false

  # Threading context for a single transform pass. Two roles live here, kept
  # visibly apart: read-only config (`file`, `mutators`, `skip_ids`, `prefix`),
  # set once; and accumulators (`next_id`, `group`, `sites`), updated as ids are
  # assigned and sites recorded. A struct (not a bare map) makes the split
  # explicit and a stray field name fail loudly. The whole struct is threaded
  # through every stage — never destructured into loose values — so the shape
  # stays uniform.

  @type t :: %__MODULE__{
          file: String.t(),
          mutators: [Mutare.Mutator.Spec.t()],
          skip_ids: MapSet.t(),
          prefix: String.t(),
          active_var: atom(),
          super_var: atom(),
          piped_var: atom(),
          cond_var: atom(),
          active_bound: boolean(),
          module_depth: non_neg_integer(),
          next_id: pos_integer(),
          group: non_neg_integer(),
          sites: [Mutare.Site.t()]
        }

  defstruct [
    # config — read-only for the pass
    :file,
    :mutators,
    :skip_ids,
    # The prefix for generated private (lifted) names. `"__mutare_"` is the
    # canonical value; `Mutare.Transform` recomputes it per file — scanning the
    # source's own definitions — to a collision-free variant when the target
    # already defines a `__mutare_`-prefixed name. `Transform` is the authority;
    # this default is just a safe, non-nil fallback.
    prefix: "__mutare_",
    # The variable a dispatcher/selector binds the active mutant id to (and the
    # lifted clauses' extra arg / guards read). `:mutare_active` canonically;
    # `Mutare.Transform` salts it per file (off `prefix`) when the source already
    # uses that identifier, so a generated guard can't capture a user's variable.
    active_var: :mutare_active,
    # The variable a dispatcher binds the super-forwarding closure to when a lifted
    # body calls `super` (`Mutare.Transform.Super`). `:mutare_super` canonically;
    # `Mutare.Transform` salts it per file like `active_var` so a `super(...)`
    # rewritten to `<super_var>.(...)` can't capture a user's variable of that name.
    super_var: :mutare_super,
    # The closure parameter a hoisted pipe stage binds the piped value to
    # (`Mutare.Transform.hoist_pipe/2`). `:mutare_piped` canonically; `Mutare.Transform`
    # salts it per file like `active_var` so a stage argument that mentions a same-named
    # source variable isn't captured by the closure param.
    piped_var: :mutare_piped,
    # The temp a refutable `if`/`unless` condition-hoist binds the match value to
    # (`Mutare.Transform.Analyze`'s condition hoisting). `:mutare_cond` canonically;
    # `Mutare.Transform` salts it per file like `active_var`. Emit substitutes it for the
    # placeholder the (id-free) analyze pass leaves behind.
    cond_var: :mutare_cond,
    # Whether `active_var` is already bound as a variable in the current emit scope, so
    # an in-place selector can read it directly (`case mutare_active do …`) instead of
    # re-reading `:persistent_term.get(...)` per site (the "hoisted active-id read"). True
    # inside a lifted base clause (the dispatcher threads it as the first parameter) and
    # inside a non-lifted function's `:do` block (a prologue binds it once); false at the
    # module/scaffold level and in a head's default-value position (evaluated in a
    # generated head clause where no binding is in scope), where the self-contained
    # `:persistent_term` read is kept. `Mutare.Transform.selector_subject/1` reads this.
    active_bound: false,
    # How many nested **module** scopes (`defmodule`/`defimpl`/`defprotocol`) the emit
    # walk is currently inside. A runtime `defmodule` in a function body is walked in
    # place, but its inner `def` bodies are a *new* scope that can't see the outer
    # function's hoisted `active_var` binding — so a selector emitted there must fall back
    # to the self-contained `:persistent_term` read (`selector_subject/1` gates the hoisted
    # form on `module_depth == 0`). `Mutare.Transform.emit/2` increments it on entering such
    # a node and decrements on leaving; 0 at the top of every function body.
    module_depth: 0,
    # accumulators — threaded and updated
    next_id: 1,
    group: 0,
    sites: []
  ]
end
