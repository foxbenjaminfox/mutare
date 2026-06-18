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
    * `Enum.intersperse` (drops the separators, returning the un-interspersed input)
    * the lazy `Stream` twins that exist — `Stream.uniq` / `uniq_by` / `dedup` /
      `dedup_by` / `intersperse` (`Stream` has no `sort`/`reverse`/`shuffle`)
    * `List.flatten`
    * `String.trim` / `String.trim_leading` / `String.trim_trailing`
    * `String.downcase` / `String.upcase` / `String.capitalize`
    * `String.reverse` / `String.normalize` / `String.replace_invalid`
    * `String.pad_leading` / `String.pad_trailing` / `String.slice`
    * `Kernel.abs` (`abs(x)` → `x`)
    * the `Kernel` binary slicers — `binary_slice/2`, `binary_slice/3`,
      `binary_part/3` (each selects a sub-binary; removing it returns the whole
      binary, the binary analogue of `String.slice`). `binary_part/2` is not a
      `Kernel` function — its only incarnation is `:erlang.binary_part/2` — so the
      Erlang form `:erlang.binary_part` (`/2` and `/3`) is removed too.
    * the analogous Erlang `:string` transforms — `trim`/`strip`/`chomp`,
      `lowercase`/`uppercase`/`titlecase`/`casefold`/`to_lower`/`to_upper`, `reverse`,
      `pad`/`left`/`right`/`centre`, `slice`/`substr`/`sub_string`

  Kept to transforms whose removal yields a same-typed, plausibly-interchangeable value.
  `String.slice` (and `:string.slice`/`substr`/`sub_string`, and the `binary_slice`/
  `binary_part` binary slicers) are included even though they *select* a part — removing
  them returns the whole input, a clean "is the slice actually exercised?" probe — but
  `String`/`:string` `replace`/`split` (and `String.first`,
  `:string.prefix`, which can return `:nomatch`) stay excluded, since they change *which*
  characters are present or change the type. `abs` fits squarely: `abs(x)` and `x` are both
  numbers and *equal* for every non-negative input, so a suite that only ever exercises
  non-negative values can't tell them apart — exactly the "did someone forget the `abs` and
  nothing noticed?" signal.

  Deliberately *excludes* `map`/`filter`/`reduce` and friends: those change *which*
  data is present, not just its order/shape, so their removal is a coarser, noisier
  mutation. This family keeps to transforms whose removal yields a same-typed,
  plausibly-interchangeable value.

  ## Bare vs qualified `Kernel` (`abs`, `binary_slice`, `binary_part`)

  A *qualified* `Kernel.abs(x)` / `Kernel.binary_slice(b, r)` carries the prefix that
  proves the function, so it is removed arity-blind alongside the remote targets. A
  *bare* `abs(x)` / `binary_slice(b, r)` has no prefix to prove it is the `Kernel` one
  (not a same-named user function), so — like the bare `Kernel` calls in
  `Mutare.Mutators.Numeric` — it is removed only at the function's true *effective*
  arity (`abs/1`, `binary_slice/2`, `binary_slice/3`, `binary_part/3`), recovered with
  the pipe flag (a pipe stage carries one fewer argument than the source reads). And when
  `import Kernel, except:/only:` has displaced it
  (`Mutare.Transform.Imports.kernel_displaced?/1`), the bare call names another module's
  function, so it is left alone. The guard-safe ones (`abs/1`, `binary_part/3`) are also
  removed inside a `when`, delivered by lifting (`abs(x) > 0` → `x > 0`, guard-legal).

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
  floor); these are remote calls, so guard-safety is automatic. Targets are recognised by
  their **resolved** module through the shared `Mutare.Transform.Calls` reader — Elixir
  (`[:Enum]`) *and* Erlang (`:string`/`:erlang`) modules alike — so a direct call, an
  aliased one (`alias Enum, as: E; E.sort(x)`; `alias :string, as: S; S.trim(x)`), and a
  bare imported one (`import Enum; sort(x)`; `import :string; trim(x)`) are all matched. Only
  a bare `Kernel` call (`abs`, the binary slicers) is handled outside the reader.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Transform.{Calls, Imports}

  # {module_key, function} — arity-agnostic: every arity of these has its input as the
  # first argument and returns a same-typed value, so removal is always legal. The module
  # key is a resolved alias path (`[:String]`) for an Elixir module (matched through
  # `Calls.resolved_call`), or a bare atom (`:string`) for an Erlang one.
  @removable MapSet.new([
               {[:Enum], :sort},
               {[:Enum], :sort_by},
               {[:Enum], :reverse},
               {[:Enum], :shuffle},
               {[:Enum], :uniq},
               {[:Enum], :uniq_by},
               {[:Enum], :dedup},
               {[:Enum], :dedup_by},
               {[:Enum], :intersperse},
               # The lazy `Stream` twins — the transparent transforms `Stream` has.
               {[:Stream], :uniq},
               {[:Stream], :uniq_by},
               {[:Stream], :dedup},
               {[:Stream], :dedup_by},
               {[:Stream], :intersperse},
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
               {[:String], :slice},
               # Qualified `Kernel.abs(x)` — the prefix proves it; `abs` exists only at
               # /1, so arity-agnostic removal is safe (`Kernel.abs(x)` → `x`).
               {[:Kernel], :abs},
               # Qualified `Kernel` binary slicers — the prefix proves them, so removal
               # is arity-blind (`Kernel.binary_slice(b, r)` → `b`). Every arity selects
               # a sub-binary from its first argument and returns a binary.
               {[:Kernel], :binary_slice},
               {[:Kernel], :binary_part},
               # `binary_part/2` is not a `Kernel` function; its only form is
               # `:erlang.binary_part/2` (the `{start, len}`-tuple arity). Remove the
               # Erlang form arity-blind — both `/2` and `/3` return their first arg.
               {:erlang, :binary_part},
               # Erlang :string — the same transparent transforms (case, trim,
               # reverse, pad/justify, substring-select), each returning a string.
               {:string, :lowercase},
               {:string, :uppercase},
               {:string, :titlecase},
               {:string, :casefold},
               {:string, :to_lower},
               {:string, :to_upper},
               {:string, :trim},
               {:string, :strip},
               {:string, :chomp},
               {:string, :reverse},
               {:string, :pad},
               {:string, :left},
               {:string, :right},
               {:string, :centre},
               {:string, :slice},
               {:string, :substr},
               {:string, :sub_string}
             ])

  # Bare `Kernel` calls keyed on {name, effective_arity}. Like Numeric's bare-Kernel
  # handling, the arity is what proves a bare `abs(x)` is the Kernel `abs/1` rather than
  # a same-named user function at another arity — so a user's `abs/2` is left alone. The
  # binary slicers exist bare at these arities only (`binary_part/2` is not a `Kernel`
  # function — see the moduledoc), so a same-named user call at any other arity is safe.
  @bare_removable MapSet.new([
                    {:abs, 1},
                    {:binary_slice, 2},
                    {:binary_slice, 3},
                    {:binary_part, 3}
                  ])

  @impl Mutare.Mutator
  def name, do: :call_removal

  # Never fires node-locally: whether to return the first arg (non-piped) or
  # Function.identity() (piped) depends on pipe context.
  @impl Mutare.Mutator
  def mutate(_node), do: :skip

  # Any stdlib call `Calls.resolved_call` recognises — an Elixir remote (aliased `Enum.sort`
  # or bare imported `import Enum; sort`) *or* an Erlang remote (direct `:string.trim`,
  # aliased `alias :string, as: S; S.trim`, bare imported `import :string; trim`) — keyed by
  # its resolved module (`[:Enum]` or `:string`). A bare `Kernel` call (which `Calls` doesn't
  # resolve) falls to `bare_removal/2`.
  @impl Mutare.Mutator
  def mutate(node, %{piped: piped?}) do
    case Calls.resolved_call(node) do
      {module, fun, args, _rebuild} ->
        removal(MapSet.member?(@removable, {module, fun}), piped?, args)

      nil ->
        bare_removal(node, piped?)
    end
  end

  def mutate(_node, _context), do: :skip

  # A bare `Kernel` call (`abs(x)`, the binary slicers): removed only at its effective arity,
  # so a same-named user call at another arity is never touched. Effective arity = visible
  # args + (piped? 1 : 0), since a pipe stage's node carries one fewer arg than the source
  # reads. A bare call displaced from `Kernel` by `import Kernel, except:/only:`
  # (`Mutare.Transform.Imports`) is another module's function, so it is left alone.
  defp bare_removal({fun, meta, args}, piped?) when is_atom(fun) and is_list(args) do
    eff_arity = Mutare.Mutator.effective_arity(args, piped?)

    removable? =
      MapSet.member?(@bare_removable, {fun, eff_arity}) and not Imports.kernel_displaced?(meta)

    removal(removable?, piped?, args)
  end

  defp bare_removal(_node, _piped?), do: :skip

  # Decide the removal given membership + pipe context.
  defp removal(false, _piped?, _args), do: :skip
  defp removal(true, true, _args), do: [identity_call()]
  defp removal(true, false, []), do: :skip
  defp removal(true, false, args), do: [hd(args)]

  defp identity_call do
    {{:., [], [{:__aliases__, [], [:Function]}, :identity]}, [], []}
  end
end
