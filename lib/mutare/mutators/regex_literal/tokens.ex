defmodule Mutare.Mutators.RegexLiteral.Tokens do
  @moduledoc false
  # The shared token reader for `Mutare.Mutators.RegexLiteral`. One positional walk over the
  # pattern produces the `[t()]` stream every mutation pass folds over, so the cross-cutting
  # lexical state lives here once: escape pairs, character classes (`in_class` / a just-opened
  # class), group structure with the `Flags` scope stack, and the spans where regex syntax does
  # not apply.
  #
  # ## Token shape — the contract the passes read
  #
  # Every token is `%{kind, text, offset, in_class, flags}`:
  #
  #   * `kind` — one of `:char :escape :class_open :class_close :range :bound :group_open
  #     :group_close :modifier :comment :inert`
  #   * `text` / `offset` — let a pass splice a replacement by `binary_part` (`before_tok`/
  #     `after_tok` in `RegexLiteral`)
  #   * `in_class` — whether the token sits inside a `[…]` class
  #   * `flags` — the effective modifier set (a `MapSet` of flag chars) in force *at that point*,
  #     honouring inline `(?m)` / `(?s:…)` scopes via the `Flags` stack
  #
  # Two kinds carry extra fields:
  #
  #   * `:bound` adds `:bound` — the parsed quantifier (`{:exact, n} | {:atleast, n} |
  #     {:range, n, m}`)
  #   * `:group_open` adds `:removable?` (a plain capturing `(`, what the alternation pass needs),
  #     `:zero_width?` (a lookaround), and `:capturing?`
  #
  # Two "syntax doesn't apply here" spans are distinguished because they differ for quantifier
  # adjacency: a **`:comment`** is *ignored* by the engine (an `x`-mode `#` line comment or a
  # `(?#…)` group), so a lazy/possessive suffix can hide behind it; an **`:inert`** is a zero-width
  # *atom* whose body isn't regex (a `\Q…\E` quote, a `(*VERB…)` control verb). Their content is
  # not lexed, so every pass skips them by not matching the kind.

  alias Mutare.Mutators.RegexLiteral.Flags

  @type kind ::
          :char
          | :escape
          | :class_open
          | :class_close
          | :range
          | :bound
          | :group_open
          | :group_close
          | :modifier
          | :comment
          | :inert

  @type bound ::
          {:exact, non_neg_integer()}
          | {:atleast, non_neg_integer()}
          | {:range, non_neg_integer(), non_neg_integer()}

  @type t :: %{
          required(:kind) => kind(),
          required(:text) => binary(),
          required(:offset) => non_neg_integer(),
          required(:in_class) => boolean(),
          required(:flags) => MapSet.t(char()),
          optional(:bound) => bound(),
          optional(:removable?) => boolean(),
          optional(:zero_width?) => boolean(),
          optional(:capturing?) => boolean()
        }

  @doc """
  Lex `pattern` into the `[t()]` token stream — the sole entry point. `baseline` is the sigil's
  own modifier set (a `MapSet` of flag chars), seeding the `Flags` scope stack.
  """
  @spec tokens(binary(), MapSet.t(char())) :: [t()]
  def tokens(pattern, baseline), do: lex(pattern, 0, false, false, Flags.initial(baseline), [])

  defp tok(kind, text, offset, in_class, stack),
    do: %{kind: kind, text: text, offset: offset, in_class: in_class, flags: hd(stack)}

  defp lex(<<>>, _i, _ic, _jo, _stack, acc), do: Enum.reverse(acc)

  # `\Q…\E` literal-quote span → one inert *atom* token (its body matches as text).
  defp lex(<<?\\, ?Q, rest::binary>>, i, ic, _jo, stack, acc) do
    {quoted, tail} = take_quoted(rest)
    text = "\\Q" <> quoted
    lex(tail, i + byte_size(text), ic, false, stack, [tok(:inert, text, i, ic, stack) | acc])
  end

  # A `\cX` control escape is a single three-byte escape — consume its argument too, so the
  # control character (which may be `(`/`)`/etc.) can't push a frame or close a class.
  defp lex(<<?\\, ?c, x::utf8, rest::binary>>, i, ic, _jo, stack, acc) do
    text = <<?\\, ?c, x::utf8>>
    lex(rest, i + byte_size(text), ic, false, stack, [tok(:escape, text, i, ic, stack) | acc])
  end

  # A PCRE backtracking control verb `(*VERB)` / `(*VERB:arg)` (outside a class). Its
  # argument is literal text that may contain `(`/`|`/etc., so the whole `(*…)` (to the
  # first `)`) is an inert atom — it must not push a frame or read as alternation.
  defp lex(<<?(, ?*, rest::binary>>, i, false, _jo, stack, acc) do
    {verb, tail} = take_verb(rest)
    text = "(*" <> verb

    lex(tail, i + byte_size(text), false, false, stack, [tok(:inert, text, i, false, stack) | acc])
  end

  # Escape pair.
  defp lex(<<?\\, c::utf8, rest::binary>>, i, ic, _jo, stack, acc) do
    text = <<?\\, c::utf8>>
    lex(rest, i + byte_size(text), ic, false, stack, [tok(:escape, text, i, ic, stack) | acc])
  end

  # Lone trailing backslash (invalid but consumed gracefully) — a literal char.
  defp lex(<<?\\>>, i, ic, _jo, stack, acc),
    do: lex(<<>>, i + 1, ic, false, stack, [tok(:char, "\\", i, ic, stack) | acc])

  # Character class open / close.
  defp lex(<<?[, ?^, rest::binary>>, i, false, _jo, stack, acc),
    do: lex(rest, i + 2, true, true, stack, [tok(:class_open, "[^", i, false, stack) | acc])

  defp lex(<<?[, rest::binary>>, i, false, _jo, stack, acc),
    do: lex(rest, i + 1, true, true, stack, [tok(:class_open, "[", i, false, stack) | acc])

  defp lex(<<?], rest::binary>>, i, true, false, stack, acc),
    do: lex(rest, i + 1, false, false, stack, [tok(:class_close, "]", i, true, stack) | acc])

  # A POSIX class `[:name:]` / `[:^name:]` *inside* a character class — consume it whole so
  # its internal `]` is never read as the outer class's close. A bare `[:…` with no closing
  # `:]` is not POSIX: the `[` is then an ordinary literal member.
  defp lex(<<?[, ?:, rest::binary>>, i, true, _jo, stack, acc) do
    case take_posix(rest) do
      {body, tail} ->
        text = "[:" <> body

        lex(tail, i + byte_size(text), true, false, stack, [
          tok(:char, text, i, true, stack) | acc
        ])

      :none ->
        lex(<<?:, rest::binary>>, i + 1, true, false, stack, [
          tok(:char, "[", i, true, stack) | acc
        ])
    end
  end

  # Character-class range `lo-hi` (alphanumeric endpoints) — a lexical unit so a consumer
  # never has to re-stitch one from single chars.
  defp lex(<<lo::utf8, ?-, hi::utf8, rest::binary>>, i, true, _jo, stack, acc)
       when (lo in ?0..?9 or lo in ?a..?z or lo in ?A..?Z) and
              (hi in ?0..?9 or hi in ?a..?z or hi in ?A..?Z) do
    text = <<lo::utf8, ?-, hi::utf8>>
    lex(rest, i + byte_size(text), true, false, stack, [tok(:range, text, i, true, stack) | acc])
  end

  # `x`-mode `#` comment (outside a class, `x` active) → an ignored `:comment` span.
  defp lex(<<?#, rest::binary>>, i, false, _jo, stack, acc) do
    if Flags.active?(stack, ?x) do
      {comment, tail} = take_comment_line(rest)
      text = "#" <> comment

      lex(tail, i + byte_size(text), false, false, stack, [
        tok(:comment, text, i, false, stack) | acc
      ])
    else
      lex(rest, i + 1, false, false, stack, [tok(:char, "#", i, false, stack) | acc])
    end
  end

  # Group open (outside a class) — `Flags.open/2` advances the flag scope and tells us
  # whether this is a real group (`:push`), a bare inline modifier (`:mutate`, no frame) or
  # a `(?#…)` comment (`:comment`). `removable?` (a plain capturing `(`, not `(?…`) is what
  # the alternation pass needs.
  defp lex(<<?(, rest::binary>>, i, false, _jo, stack, acc) do
    {action, consumed, tail, stack2} = Flags.open(rest, stack)
    text = "(" <> consumed
    next = i + byte_size(text)

    token =
      case action do
        :comment ->
          tok(:comment, text, i, false, stack)

        :mutate ->
          tok(:modifier, text, i, false, stack)

        :push ->
          tok(:group_open, text, i, false, stack)
          |> Map.put(:removable?, not modifier_open?(rest))
          |> Map.put(:zero_width?, lookaround?(rest))
          |> Map.put(:capturing?, capturing?(rest))
      end

    lex(tail, next, false, false, stack2, [token | acc])
  end

  defp lex(<<?), rest::binary>>, i, false, _jo, stack, acc),
    do:
      lex(rest, i + 1, false, false, Flags.close(stack), [
        tok(:group_close, ")", i, false, stack) | acc
      ])

  # Bounded quantifier `{n,m}` (a valid bound, outside a class) → one token carrying the
  # parsed bound; an invalid `{` is a literal char.
  defp lex(<<?{, rest::binary>>, i, false, _jo, stack, acc) do
    case parse_bound(rest) do
      {:ok, bound, tail} ->
        text = "{" <> binary_part(rest, 0, byte_size(rest) - byte_size(tail))
        token = Map.put(tok(:bound, text, i, false, stack), :bound, bound)
        lex(tail, i + byte_size(text), false, false, stack, [token | acc])

      :error ->
        lex(rest, i + 1, false, false, stack, [tok(:char, "{", i, false, stack) | acc])
    end
  end

  # Any other single codepoint (an anchor `^`/`$`, the dot, a quantifier `*`/`+`/`?`, a
  # pipe, a class member, a plain literal…). Consumers dispatch on `text`.
  defp lex(<<c::utf8, rest::binary>>, i, ic, _jo, stack, acc),
    do:
      lex(rest, i + byte_size(<<c::utf8>>), ic, false, stack, [
        tok(:char, <<c::utf8>>, i, ic, stack) | acc
      ])

  defp modifier_open?(<<??, _::binary>>), do: true
  defp modifier_open?(_), do: false

  # Is this group (the bytes after `(`) a zero-width *lookaround* assertion? Quantifying a
  # *capture-free* one is idempotent, which the scan pass uses to suppress guaranteed-
  # equivalent collapse/lazy/bound variants. (A named group `(?<n>…)` is *not* a lookbehind —
  # only `(?<=`/`(?<!` are.)
  defp lookaround?(<<??, ?=, _::binary>>), do: true
  defp lookaround?(<<??, ?!, _::binary>>), do: true
  defp lookaround?(<<??, ?<, ?=, _::binary>>), do: true
  defp lookaround?(<<??, ?<, ?!, _::binary>>), do: true
  defp lookaround?(_), do: false

  # Is this group a **capturing** group — a plain `(…)` or a *named* capture
  # (`(?<n>…)`/`(?'n'…)`/`(?P<n>…)`)? A capture inside a lookaround makes its repetition
  # observable (the captured text, or a later backreference, differs), so such a lookaround is
  # *not* idempotent. Everything else `(?:`, `(?=`, `(?>`, `(?#`, `(?flags…)`, `(?<=`/`(?<!`)
  # is non-capturing.
  defp capturing?(<<??, ?P, ?<, _::binary>>), do: true
  defp capturing?(<<??, ?<, ?=, _::binary>>), do: false
  defp capturing?(<<??, ?<, ?!, _::binary>>), do: false
  defp capturing?(<<??, ?<, _::binary>>), do: true
  defp capturing?(<<??, ?', _::binary>>), do: true
  defp capturing?(<<??, _::binary>>), do: false
  defp capturing?(_), do: true

  # --- inert / span body readers -------------------------------------------

  # Consume a `\Q…\E` literal span (the bytes after `\Q`), up to and including the `\E`
  # (or to the pattern's end). Returns `{quoted, rest}`.
  defp take_quoted(bin), do: take_quoted(bin, "")
  defp take_quoted(<<?\\, ?E, rest::binary>>, acc), do: {acc <> "\\E", rest}
  defp take_quoted(<<>>, acc), do: {acc, ""}
  defp take_quoted(<<c::utf8, rest::binary>>, acc), do: take_quoted(rest, acc <> <<c::utf8>>)

  # Consume a control-verb body (the bytes after `(*`), up to and including the first `)`
  # (or to the pattern's end). The argument is literal, so `(`/`|` inside don't matter.
  defp take_verb(bin), do: take_verb(bin, "")
  defp take_verb(<<?), rest::binary>>, acc), do: {acc <> ")", rest}
  defp take_verb(<<>>, acc), do: {acc, ""}
  defp take_verb(<<c::utf8, rest::binary>>, acc), do: take_verb(rest, acc <> <<c::utf8>>)

  # Consume a POSIX-class body (the bytes after `[:`), up to and including the closing `:]`;
  # `:none` if there is no `:]` (then the leading `[` was an ordinary class member).
  defp take_posix(bin), do: take_posix(bin, "")
  defp take_posix(<<?:, ?], rest::binary>>, acc), do: {acc <> ":]", rest}
  defp take_posix(<<>>, _acc), do: :none
  defp take_posix(<<c::utf8, rest::binary>>, acc), do: take_posix(rest, acc <> <<c::utf8>>)

  # Consume an `x`-mode comment body up to (not including) the terminating newline. PCRE
  # ends the comment at the first CR *or* LF, so we stop at either (a following `.` is then
  # active, not swallowed).
  defp take_comment_line(bin), do: take_comment_line(bin, "")
  defp take_comment_line(<<c, _::binary>> = rest, acc) when c in [?\n, ?\r], do: {acc, rest}
  defp take_comment_line(<<>>, acc), do: {acc, ""}

  defp take_comment_line(<<c::utf8, rest::binary>>, acc),
    do: take_comment_line(rest, acc <> <<c::utf8>>)

  # --- bound parsing -------------------------------------------------------

  defp parse_bound(s) do
    case take_digits(s, "") do
      {"", _rest} ->
        :error

      {n, <<?}, tail::binary>>} ->
        {:ok, {:exact, String.to_integer(n)}, tail}

      {n, <<?,, after_comma::binary>>} ->
        case take_digits(after_comma, "") do
          {"", <<?}, tail::binary>>} ->
            {:ok, {:atleast, String.to_integer(n)}, tail}

          {m, <<?}, tail::binary>>} ->
            {:ok, {:range, String.to_integer(n), String.to_integer(m)}, tail}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp take_digits(<<d, rest::binary>>, acc) when d in ?0..?9, do: take_digits(rest, acc <> <<d>>)
  defp take_digits(s, acc), do: {acc, s}
end
