defmodule Mutare.Mutators.CallRemoval do
  @moduledoc """
  Removes a call that transforms its first argument and returns that argument instead.

  The following calls are supported at every available arity:

    * `Enum.sort` / `Enum.sort_by` / `Enum.reverse` / `Enum.shuffle`
    * `Enum.uniq` / `Enum.uniq_by` / `Enum.dedup` / `Enum.dedup_by`
    * `Enum.intersperse`
    * `Stream.uniq` / `Stream.uniq_by` / `Stream.dedup` / `Stream.dedup_by` /
      `Stream.intersperse`
    * `List.flatten`
    * `Map.delete` / `Map.drop` / `Map.take`, and the corresponding `Keyword` calls
    * `List.delete` / `List.delete_at` / `List.keydelete`
    * `String.trim` / `String.trim_leading` / `String.trim_trailing`
    * `String.downcase` / `String.upcase` / `String.capitalize`
    * `String.reverse` / `String.normalize` / `String.replace_invalid`
    * `String.pad_leading` / `String.pad_trailing` / `String.slice` / `String.byte_slice`
    * `URI.encode_www_form` / `URI.decode_www_form`
    * `NaiveDateTime.beginning_of_day` / `NaiveDateTime.end_of_day`
    * `Date.beginning_of_month` / `Date.end_of_month` / `Date.beginning_of_week` /
      `Date.end_of_week`
    * `Kernel.abs` (`abs(x)` → `x`)
    * `Kernel.binary_slice/2,3`, `Kernel.binary_part/3`, and
      `:erlang.binary_part/2,3`
    * the corresponding Erlang `:string` transforms — `trim`/`strip`/`chomp`,
      `lowercase`/`uppercase`/`titlecase`/`casefold`/`to_lower`/`to_upper`, `reverse`,
      `pad`/`left`/`right`/`centre`, `slice`/`substr`/`sub_string`

  The list is limited to calls whose first argument and result have compatible types.
  Slicing calls are included because returning the whole input remains type-compatible.
  Calls such as `map`, `filter`, `reduce`, `replace`, and `split` are excluded.

  A regular call is replaced by its first argument: `Enum.sort(xs)` becomes `xs`.
  A pipe stage is replaced by `Function.identity/1`. Guard-safe removals, such as
  `abs(x)`, also apply inside guards.

  This family is enabled by default. It matches aliased and imported calls, including
  Erlang modules. Bare `Kernel` calls match only at their defined arities, so a
  same-named local function is not removed.
  """
  @behaviour Mutare.Mutator

  alias Mutare.Mutators.Helpers

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
               # `Map`/`Keyword` key strippers — each returns the same kind of collection
               # with keys removed (`delete`/`drop`) or only the named keys kept (`take`),
               # so removal returns the original collection. `delete`/`take`/`drop` are all
               # single-arity except `Keyword.delete/3` (the deprecated key+value form),
               # whose first arg is still the keyword list — so arity-blind removal is safe.
               {[:Map], :delete},
               {[:Map], :drop},
               {[:Map], :take},
               {[:Keyword], :delete},
               {[:Keyword], :drop},
               {[:Keyword], :take},
               # `List` element strippers — drop one element by value (`delete`), index
               # (`delete_at`), or tuple-key (`keydelete`), each returning a list.
               {[:List], :delete},
               {[:List], :delete_at},
               {[:List], :keydelete},
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
               {[:String], :byte_slice},
               # `URI` form-encoding — `binary() -> binary()`, so removal returns the
               # raw binary (the en/decoding step is the "is it exercised?" probe).
               {[:URI], :encode_www_form},
               {[:URI], :decode_www_form},
               # `NaiveDateTime` day-boundary normalizers — each maps a timestamp to a
               # `NaiveDateTime` on the same day, so removal returns the original.
               {[:NaiveDateTime], :beginning_of_day},
               {[:NaiveDateTime], :end_of_day},
               # `Date` period-boundary normalizers — each snaps a date to a month/week
               # boundary and returns a `Date`, so removal returns the original date (the
               # `Date`-level analogue of the `NaiveDateTime` day-boundary normalizers).
               {[:Date], :beginning_of_month},
               {[:Date], :end_of_month},
               {[:Date], :beginning_of_week},
               {[:Date], :end_of_week},
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

  # Any stdlib call `Calls.resolved_call` recognises — an Elixir remote (aliased `Enum.sort`
  # or bare imported `import Enum; sort`) *or* an Erlang remote (direct `:string.trim`,
  # aliased `alias :string, as: S; S.trim`, bare imported `import :string; trim`) — keyed by
  # its resolved module (`[:Enum]` or `:string`). A bare `Kernel` call (which `Calls` doesn't
  # resolve) falls to `bare_removal/2`.
  @impl Mutare.Mutator
  def mutate(node, %{pipe_mode: pipe_mode}) do
    case Helpers.remove_call(node, pipe_mode, @removable) do
      :skip -> bare_removal(node, pipe_mode)
      mutants -> mutants
    end
  end

  # A bare `Kernel` call (`abs(x)`, the binary slicers) — removed only at its effective arity
  # (so a same-named user call at another arity is never touched, and a call displaced from
  # `Kernel` by `import Kernel, except:/only:` is left alone). `Calls.resolved_call` doesn't
  # resolve bare `Kernel`, so the shared bare-`Kernel` removal helper matches it on arity.
  defp bare_removal(node, pipe_mode),
    do: Helpers.remove_bare_kernel(node, pipe_mode, @bare_removable)
end
