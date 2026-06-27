defmodule Mutare.Mutators.RegexLiteral.Flags do
  @moduledoc """
  Positional flag-scope tracking for a regex pattern.

  A regex's *effective* option flags (`i`/`m`/`s`/`x`/`u`/…) are not a single set for
  the whole pattern: an **inline modifier** changes them *positionally*, so the same
  `^` can be multiline in one place and not in another. This module models that, so a
  mode-aware mutator (anchor swaps today; a dotall-aware `.`, a caseless mutation, …
  tomorrow) can ask "is flag X active *here*?" rather than reading one global boolean.

  ## The model — a scope stack

  The state is a **stack of flag sets** (`MapSet` of flag bytes), innermost on top, the
  baseline (the sigil's own modifiers) at the bottom. As a left-to-right byte walk meets
  group boundaries *outside a character class* it threads the stack through `open/2` and
  `close/1`, and reads the current frame with `active?/2`:

    * **scoped** `(?flags:…)` / `(?flags-flags:…)` — *push* a frame = current ∪ adds ∖
      removes. The matching `)` pops it (so the change is confined to the group).
    * **bare** `(?flags)` / `(?-flags)` — *mutate the current (top) frame in place* and
      push **nothing**. Because that frame is popped by the enclosing group's `)`, the
      change automatically applies to "the rest of the enclosing group" — PCRE's exact
      semantics — and is inherited by nested groups (which push a copy of the mutated
      frame). At the top level there is no enclosing `)`, so it runs to the pattern end.
    * **ordinary** group / lookaround / named capture / atomic / conditional / `(?:` —
      push a copy of the current frame (no flag change). Recursion/backref atoms like
      `(?R)`/`(?P=n)` self-balance through the same push/pop and are harmless.
    * **comment** `(?#…)` — swallowed whole (its body is not regex), no flag change.

  `open/2`'s job is purely to classify the opener and update the stack; the consuming
  walk keeps doing its own escape/character-class tracking (a `(` inside `[…]` is a
  literal and never reaches here).

  ## Boundaries

  Only the genuine inline-flag letters (`i m s x u U J n`) are recognised as a modifier
  group; an unknown future letter degrades to an *ordinary* group (safe — no spurious
  flag change). `x`-mode whitespace/`#`-comment stripping is **not** modelled
  (we don't tokenize x-mode), which can only ever *miss* a flag change inside an x-mode
  comment, never invent one — consistent with how an unrecognised construct fails safe.
  """

  # Letters legal inside an inline `(?…)` modifier group. Deliberately excludes the
  # letters that *introduce a construct* — `P` (named), `R` (recursion), `C` (callout) —
  # so a named group `(?P<n>…)` is never misread as a flag set.
  @inline_flags ~c"imsxuUJn"

  @type stack :: [MapSet.t()]

  @doc "The initial single-frame stack from the sigil's baseline flag bytes."
  @spec initial(MapSet.t()) :: stack
  def initial(%MapSet{} = baseline), do: [baseline]

  @doc "Is `flag` (a byte, e.g. `?m`) active in the innermost scope?"
  @spec active?(stack, byte) :: boolean
  def active?([current | _], flag), do: MapSet.member?(current, flag)

  @doc """
  Process a group **opener**. `after_paren` is the pattern slice immediately after a `(`
  encountered outside a character class. Returns `{consumed, rest, stack}`:

    * `consumed` — the extra bytes the opener itself swallowed (the `?flags:` / `?flags)`
      / `?#…)`; `""` for an ordinary group), so the caller can rebuild its prefix.
    * `rest` — the pattern remaining after `consumed`.
    * `stack` — the updated scope stack.
  """
  @spec open(binary, stack) :: {binary, binary, stack}
  def open(after_paren, stack) do
    case classify(after_paren) do
      {:comment, consumed, rest} ->
        {consumed, rest, stack}

      {:scoped, add, remove, consumed, rest} ->
        {consumed, rest, [merge(hd(stack), add, remove) | stack]}

      {:bare, add, remove, consumed, rest} ->
        {consumed, rest, [merge(hd(stack), add, remove) | tl(stack)]}

      :group ->
        {"", after_paren, [hd(stack) | stack]}
    end
  end

  @doc "Process a group **closer** `)` (outside a class): pop, never below the baseline."
  @spec close(stack) :: stack
  def close([_only] = stack), do: stack
  def close([_inner | outer]), do: outer

  # --- classification ------------------------------------------------------

  # `(?#…)` comment — swallow to the next `)` (a comment body is not regex).
  defp classify(<<??, ?#, rest::binary>>), do: take_comment(rest, "?#")

  # `(?…` — a flag run terminated by `:` (scoped) or `)` (bare); anything else is an
  # ordinary `?`-introduced construct (`(?:`, `(?=`, `(?<n>`, `(?>`, `(?(`, …).
  defp classify(<<??, rest::binary>>) do
    {run, tail} = take_flags(rest, "")

    case tail do
      <<?:, body::binary>> ->
        {add, remove} = split_flags(run)
        {:scoped, add, remove, "?" <> run <> ":", body}

      <<?), body::binary>> when run != "" ->
        {add, remove} = split_flags(run)
        {:bare, add, remove, "?" <> run <> ")", body}

      _ ->
        :group
    end
  end

  # A plain `(` capturing group.
  defp classify(_after_paren), do: :group

  defp take_flags(<<c, rest::binary>>, acc) when c in @inline_flags or c == ?-,
    do: take_flags(rest, acc <> <<c>>)

  defp take_flags(rest, acc), do: {acc, rest}

  defp take_comment(<<?), rest::binary>>, acc), do: {:comment, acc <> ")", rest}
  defp take_comment(<<c::utf8, rest::binary>>, acc), do: take_comment(rest, acc <> <<c::utf8>>)
  defp take_comment(<<>>, acc), do: {:comment, acc, ""}

  # `i-mx` → add `i`, remove `mx`; `im` → add `im`; `-m` → remove `m`.
  defp split_flags(run) do
    case String.split(run, "-", parts: 2) do
      [add] -> {to_set(add), MapSet.new()}
      [add, remove] -> {to_set(add), to_set(remove)}
    end
  end

  defp to_set(str), do: str |> String.to_charlist() |> MapSet.new()

  defp merge(set, add, remove), do: set |> MapSet.union(add) |> MapSet.difference(remove)
end
