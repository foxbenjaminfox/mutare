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

  Kept to transforms whose removal yields a same-typed, plausibly-interchangeable value
  — so `String.replace`/`slice`/`first` (which change *which* characters, or select a
  part) are excluded, the string-side counterpart of dropping `map`/`filter`/`reduce`.

  Deliberately *excludes* `map`/`filter`/`reduce` and friends: those change *which*
  data is present, not just its order/shape, so their removal is a coarser, noisier
  mutation. This family keeps to transforms whose removal yields a same-typed,
  plausibly-interchangeable value.

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
  floor); these are remote calls, so guard-safety is automatic.
  """
  @behaviour Mutare.Mutator

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
               {[:String], :pad_trailing}
             ])

  @impl Mutare.Mutator
  def name, do: :call_removal

  # Never fires node-locally: whether to return the first arg (non-piped) or
  # Function.identity() (piped) depends on pipe context.
  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  @impl Mutare.Mutator
  def mutate({{:., _dm, [{:__aliases__, _am, mod}, fun]}, _cm, args}, %{piped: piped?})
      when is_list(args) do
    cond do
      not MapSet.member?(@removable, {mod, fun}) -> :skip
      # Piped: the input is the |> LHS, supplied to identity by the pipe.
      piped? -> [identity_call()]
      # Non-piped: drop the call, keep its first argument (the input).
      args == [] -> :skip
      true -> [hd(args)]
    end
  end

  def mutate(_node, _context), do: :skip

  defp identity_call do
    {{:., [], [{:__aliases__, [], [:Function]}, :identity]}, [], []}
  end
end
