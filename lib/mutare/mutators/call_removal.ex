defmodule Mutare.Mutators.CallRemoval do
  @moduledoc """
  Remove a *transparent transform* — a call that reorders, strips, pads, dedups, or
  normalizes its first argument — leaving the raw input. The classic "non-void method
  call removal" operator, asking: does this tidying step matter, or did someone *forget*
  it and nothing noticed?

  Targets (any arity — the first argument is always the value being transformed, and
  the result is the same kind of thing, so dropping the call stays compile-safe):

    * `Enum.sort` / `Enum.sort_by` / `Enum.reverse` / `Enum.shuffle`
    * `Enum.uniq` / `Enum.uniq_by` / `Enum.dedup` / `Enum.dedup_by`
    * `List.flatten`
    * `String.trim` / `String.trim_leading` / `String.trim_trailing`
    * `String.downcase` / `String.upcase` / `String.capitalize`
    * `String.reverse` / `String.normalize` / `String.replace_invalid`
    * `String.pad_leading` / `String.pad_trailing`
    * `Kernel.abs` (`abs(x)` → `x`)

  Kept to transforms whose removal yields a same-typed, plausibly-interchangeable value
  — so `String.replace`/`slice`/`first` (which change *which* characters, or select a
  part) are excluded, the string-side counterpart of dropping `map`/`filter`/`reduce`.
  `abs` fits squarely: `abs(x)` and `x` are both numbers and *equal* for every
  non-negative input, so a suite that only ever exercises non-negative values can't
  tell them apart — exactly the "did someone forget the `abs` and nothing noticed?"
  signal.

  Deliberately *excludes* `map`/`filter`/`reduce` and friends: those change *which*
  data is present, not just its order/shape, so their removal is a coarser, noisier
  mutation. This family keeps to transforms whose removal yields a same-typed,
  plausibly-interchangeable value.

  ## `abs`: bare vs qualified `Kernel`

  A *qualified* `Kernel.abs(x)` carries the prefix that proves the function, so it is
  removed arity-blind alongside the remote targets. A *bare* `abs(x)` has no prefix to
  prove it is the `Kernel` one (not a same-named user function), so — like the bare
  `Kernel` calls in `Mutare.Mutators.Numeric` — it is removed only at `abs`'s true
  *effective* arity (`/1`), recovered with the pipe flag (a pipe stage carries one
  fewer argument than the source reads). `abs/1` is guard-safe, so a bare `abs` in a
  `when` is removed too, delivered by lifting (`abs(x) > 0` → `x > 0`, guard-legal).

  ## Why it's pipe-aware (`mutate/2`, never `mutate/1`)

  Non-piped, removal is node-local: `Enum.sort(x)` → `x` (return the first argument).
  But a pipe stage carries one fewer argument than the source reads (the input is the
  `|>` left side, not in the call), so `x |> Enum.sort(cmp)` reaches a mutator as a
  1-arg `Enum.sort(cmp)`, indistinguishable from a non-piped `Enum.sort(cmp)` — and
  returning the bare `cmp` there would be nonsense. So it implements the optional
  `mutate/2` callback, which `Mutare.Transform` invokes with `%{piped: boolean}`:

    * **non-piped** → the first argument (`Enum.sort(x)` → `x`), the cleanest diff;
    * **piped** → `Function.identity()`, so `x |> Enum.sort()` becomes
      `x |> Function.identity()` ≡ `Function.identity(x)` ≡ `x`. A pipe stage can't be
      made to *vanish* inside a selector, and `Function.identity/1` is the minimal,
      compile-safe, honest no-op that rides the existing `hoist_pipe` path unchanged.

  On by default. `Function.identity/1` exists since Elixir 1.10 (well under the 1.18
  floor); these are remote calls, so guard-safety is automatic. Recognises the targets by
  their resolved module (`Mutare.Transform.Aliases`), so an aliased call is matched too.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Transform.Aliases

  # {alias_path, function} — arity-agnostic: every arity of these has its input as
  # the first argument and returns a same-typed value, so removal is always legal.
  @removable MapSet.new([
               {[:Enum], :sort},
               {[:Enum], :sort_by},
               {[:Enum], :reverse},
               {[:Enum], :shuffle},
               {[:Enum], :uniq},
               {[:Enum], :uniq_by},
               {[:Enum], :dedup},
               {[:Enum], :dedup_by},
               {[:List], :flatten},
               {[:String], :trim},
               {[:String], :trim_leading},
               {[:String], :trim_trailing},
               {[:String], :downcase},
               {[:String], :upcase},
               {[:String], :capitalize},
               {[:String], :reverse},
               {[:String], :normalize},
               {[:String], :replace_invalid},
               {[:String], :pad_leading},
               {[:String], :pad_trailing},
               # Qualified `Kernel.abs(x)` — the prefix proves it; `abs` exists only at
               # /1, so arity-agnostic removal is safe (`Kernel.abs(x)` → `x`).
               {[:Kernel], :abs}
             ])

  # Bare `Kernel` calls keyed on {name, effective_arity}. Like Numeric's bare-Kernel
  # handling, the arity is what proves a bare `abs(x)` is the Kernel `abs/1` rather than
  # a same-named user function at another arity — so a user's `abs/2` is left alone.
  @bare_removable MapSet.new([{:abs, 1}])

  @impl Mutare.Mutator
  def name, do: :call_removal

  # Never fires node-locally: whether to return the first arg (non-piped) or
  # Function.identity() (piped) depends on pipe context.
  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  @impl Mutare.Mutator
  def mutate({{:., _dm, [{:__aliases__, am, mod}, fun]}, _cm, args}, %{piped: piped?})
      when is_list(args) do
    cond do
      not MapSet.member?(@removable, {Aliases.resolved_module(am, mod), fun}) -> :skip
      # Piped: the input is the |> LHS, supplied to identity by the pipe.
      piped? -> [identity_call()]
      # Non-piped: drop the call, keep its first argument (the input).
      args == [] -> :skip
      true -> [hd(args)]
    end
  end

  # A bare `Kernel` call (`abs(x)`): removed only at its effective arity, so a same-named
  # user call at another arity is never touched. Effective arity = visible args + (piped?
  # 1 : 0), since a pipe stage's node carries one fewer arg than the source reads.
  def mutate({fun, _meta, args}, %{piped: piped?})
      when is_atom(fun) and is_list(args) do
    eff_arity = length(args) + if(piped?, do: 1, else: 0)

    cond do
      not MapSet.member?(@bare_removable, {fun, eff_arity}) -> :skip
      # `value |> abs()` — 0 visible args; the input is the |> LHS, fed to identity.
      piped? -> [identity_call()]
      # `abs(x)` — drop the call, keep its only argument.
      true -> [hd(args)]
    end
  end

  def mutate(_node, _context), do: :skip

  defp identity_call do
    {{:., [], [{:__aliases__, [], [:Function]}, :identity]}, [], []}
  end
end
