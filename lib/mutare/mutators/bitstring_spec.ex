defmodule Mutare.Mutators.BitstringSpec do
  @moduledoc """
  Unicode bitstring-specifier mutation: swap a segment's **text encoding** and
  **byte order** in a `<<…>>` *constructor*. The fault model is a wrong
  representation choice in binary I/O — encoding a codepoint as the wrong UTF
  width, or with the wrong endianness — exactly the "looks right, subtly wrong"
  bug that codec / protocol / file-format code should pin down and that nothing
  else here reaches (the whole spec side of a `::` segment is otherwise excluded).

  Two axes, both **never-equivalent and compile-safe by construction** — the
  reason this is the only spec-position family worth running:

    * **encoding** — `utf8 ↔ utf16 ↔ utf32` (a 3-way swap, so each utf segment
      yields two encoding mutants). The three share one validity domain (a valid
      Unicode scalar; a surrogate / over-max value raises identically for all
      three), so a swap *never* turns a working segment into a crashing one — it
      only changes the bytes emitted, which is precisely the observable a test
      should catch. And every codepoint encodes to different bytes under each
      width (`?h` → `<<104>>` / `<<0, 104>>` / `<<0, 0, 0, 104>>`), so no swap is
      an equivalent no-op.
    * **byte order** — `big ↔ little`, only for `utf16`/`utf32` (a `utf8` segment
      is byte-oriented; endianness is meaningless on it). A bare `<<x::utf16>>`
      defaults to big-endian, so it earns one mutant that *adds* `-little`; an
      explicit `utf16-big`/`utf16-little` flips to the other. Two exclusions keep
      this axis *exactly* never-equivalent. `native` is left untouched as **source
      and target** — it resolves to the host's endianness, so a `native` swap
      would be equivalent on one architecture and not another (an
      unkillable-or-flaky mutant). And a swap on a **literal** codepoint whose
      encoding is byte-palindromic (`<<0::utf16>>` is `<<0, 0>>` in either order —
      so `0`/NUL, and any `cp = b * 257` in utf16; `<<0::utf32>>` likewise) is
      **skipped**, since it would emit identical bytes. A swap on a *variable*
      value stays — it is killable by some input, so it is a real mutant, not an
      equivalent one.

  Delivery is positional and needs nothing special: the whole `<<…>>` node is
  offered to `mutate/1` only in a **runtime body** (a constructor — where the
  in-place selector legally wraps it, the same path `BitstringLiteral` rides), and
  each mutant is a *complete* `<<…>>` with one segment's spec rewritten. So a
  spec in a **pattern** (`<<cp::utf16, rest::binary>> = decode(x)` — the decoding
  side, where the matching bug bites) is *not* reached: a selector can't wrap a
  pattern, and a spec atom isn't a literal the lift / tuple-the-scrutinee paths
  carry. v1 catches encoders, not decoders — a deliberate, documented gap.

  Not mutated: an **interpolated string** (`"a\#{x}b"`, a `<<>>` with a
  `:delimiter` — `StringLiteral`'s domain, and its segments are `::binary`, never
  utf anyway); a segment with no utf encoding (`integer`/`binary`/`float`/…, a
  `size`/`unit`-bearing spec — none of which a utf segment can carry). The segment
  *values* still mutate independently via their own families.
  """
  @behaviour Mutare.Mutator

  # The three Unicode codepoint encodings, mutually swappable.
  @encodings [:utf8, :utf16, :utf32]

  # The architecture-independent byte orders. `:native` is deliberately absent —
  # it resolves to the host endianness, so mutating to/from it risks an
  # equivalent-on-this-host mutant (see the moduledoc).
  @byte_orders [:big, :little]

  @impl Mutare.Mutator
  def name, do: :bitstring_spec

  @impl Mutare.Mutator
  def mutate({:<<>>, meta, segments})
      when is_list(meta) and is_list(segments) and segments != [] do
    # A `:delimiter` marks an interpolated string (a `<<>>` written as `"…"`); its
    # segments are `::binary`, never utf — leave it to StringLiteral's domain.
    if Keyword.has_key?(meta, :delimiter) do
      :skip
    else
      case whole_node_mutants(meta, segments) do
        [] -> :skip
        mutants -> mutants
      end
    end
  end

  def mutate(_node), do: :skip

  # For each segment that carries a utf encoding, emit a *whole* `<<…>>` copy per
  # spec variant — only the one segment differs, so the diff reads as the single
  # `utf8` → `utf16` (or `…-big` → `…-little`) swap.
  defp whole_node_mutants(meta, segments) do
    segments
    |> Enum.with_index()
    |> Enum.flat_map(fn {segment, index} ->
      Enum.map(spec_variants(segment), fn new_segment ->
        {:<<>>, meta, List.replace_at(segments, index, new_segment)}
      end)
    end)
  end

  # The mutated *segments* for one `<<…>>` segment: the encoding and byte-order
  # variants of its spec, rewrapped as `value::new_spec`. A non-`::` segment (a
  # bare value) or one whose spec has no utf encoding yields none.
  defp spec_variants({:"::", smeta, [value, spec]}) do
    case find_atom(spec, @encodings) do
      nil ->
        []

      enc ->
        Enum.map(
          encoding_variants(spec, enc) ++ order_variants(spec, enc, value),
          &{:"::", smeta, [value, &1]}
        )
    end
  end

  defp spec_variants(_bare_value), do: []

  # Swap the encoding atom for each of the other two. To `utf8` we drop any byte
  # order (a utf spec carries only encoding + optional endianness, so the result
  # is a clean bare `utf8` — and endianness is meaningless on utf8); to
  # `utf16`/`utf32` we keep the existing modifiers in place.
  defp encoding_variants(spec, enc) do
    for target <- @encodings, target != enc do
      if target == :utf8,
        do: bare_encoding(spec, :utf8),
        else: replace_atom(spec, enc, target)
    end
  end

  # The byte-order mutant(s) of a utf16/utf32 spec. An explicit `big`/`little`
  # flips to the other; a `native` is left alone; an implicit order (no atom —
  # the language default of `big`) earns an added `-little`. utf8 has no byte
  # order, so it gets none. A swap is **skipped** when the segment's value is a
  # literal codepoint whose encoding is byte-palindromic (`<<0::utf16>>` is
  # `<<0, 0>>` either way; `<<0x0101::utf16>>` is `<<1, 1>>`): the mutant emits
  # identical bytes — an unkillable equivalent — and dropping it is what keeps the
  # byte-order axis exactly never-equivalent (see the moduledoc).
  defp order_variants(_spec, :utf8, _value), do: []

  defp order_variants(spec, enc, value) do
    if symmetric_order?(value, enc) do
      []
    else
      case find_atom(spec, [:native | @byte_orders]) do
        :big -> [replace_atom(spec, :big, :little)]
        :little -> [replace_atom(spec, :little, :big)]
        :native -> []
        nil -> [append_atom(spec, :little)]
      end
    end
  end

  # --- spec-tree helpers -----------------------------------------------------
  #
  # A bitstring spec is a single atom node (`{:utf16, m, nil}`) or a left-nested
  # `-` chain of them (`utf16-little` → `{:-, m, [{:utf16, …}, {:little, …}]}`).
  # The deprecated-but-compiling parenthesized form (`utf16-big()`) parses its
  # modifier as a zero-arg call (`{:big, m, []}`, context `[]`, not `nil`), so the
  # readers must treat an **empty-list** context as a leaf atom too — else a
  # `big()` order goes unseen, the spec looks orderless, and `order_variants` adds
  # a *second*, conflicting `-little` (`utf16-big()-little` → "conflicting
  # endianness", a build-poisoning mutant). A non-empty arg list (`size(8)`) is a
  # real call, not a spec atom. We rewrite atoms *in place* (preserving every other
  # node's metadata, so the render stays faithful) rather than flatten-and-rebuild
  # (which would drop the `-` nodes' meta and re-render with stray spaces).

  # The first leaf atom belonging to `set`, or nil.
  defp find_atom({:-, _, [left, right]}, set), do: find_atom(left, set) || find_atom(right, set)

  defp find_atom({atom, _, ctx}, set)
       when is_atom(atom) and (is_nil(ctx) or is_atom(ctx) or ctx == []),
       do: if(atom in set, do: atom)

  defp find_atom(_other, _set), do: nil

  # Replace the leaf atom `old` with `new`, keeping its metadata; other nodes pass
  # through untouched.
  defp replace_atom({:-, m, [left, right]}, old, new),
    do: {:-, m, [replace_atom(left, old, new), replace_atom(right, old, new)]}

  defp replace_atom({old, m, ctx}, old, new), do: {new, m, ctx}
  defp replace_atom(node, _old, _new), do: node

  # The bare encoding atom alone (dropping any byte-order modifier), reusing the
  # encoding leaf's metadata for position fidelity.
  defp bare_encoding(spec, atom) do
    {_, m, ctx} = encoding_leaf(spec)
    {atom, m, ctx}
  end

  defp encoding_leaf({:-, _, [left, right]}), do: encoding_leaf(left) || encoding_leaf(right)
  defp encoding_leaf({atom, _, _} = leaf) when atom in @encodings, do: leaf
  defp encoding_leaf(_other), do: nil

  # Append a `-modifier` to a spec that has none (e.g. bare `utf16` → `utf16-little`).
  # The generated `-`/atom nodes carry clean meta; the formatter renders the
  # specifier separator tight.
  defp append_atom(spec, atom), do: {:-, [], [spec, {atom, [], nil}]}

  # --- literal byte-order symmetry -------------------------------------------
  #
  # A `big`/`little` swap is observable only when the value's two-/four-byte
  # encoding actually differs between the orders. For a **literal integer**
  # codepoint we decide that statically — encode it both ways and compare — and
  # skip the swap on a byte-palindromic value (`0` → `<<0, 0>>`, `0x0101` →
  # `<<1, 1>>`), an equivalent no-op. A non-literal value (a variable) is *not*
  # skipped: its swap is killable by some input, so it is a real mutant.

  defp symmetric_order?(value, enc) do
    with {:ok, cp} when is_integer(cp) <- Mutare.AST.literal_value(value),
         {:ok, {big, little}} <- order_bytes(cp, enc) do
      big == little
    else
      _ -> false
    end
  end

  # The big- and little-endian encodings of `cp` under `enc`, or `:error` if `cp`
  # is not an encodable Unicode scalar (a surrogate / over-max raises identically
  # for both orders) — in which case we keep the mutant rather than guess.
  defp order_bytes(cp, enc) do
    {:ok, {encode(cp, enc, :big), encode(cp, enc, :little)}}
  rescue
    ArgumentError -> :error
  end

  defp encode(cp, :utf16, :big), do: <<cp::utf16-big>>
  defp encode(cp, :utf16, :little), do: <<cp::utf16-little>>
  defp encode(cp, :utf32, :big), do: <<cp::utf32-big>>
  defp encode(cp, :utf32, :little), do: <<cp::utf32-little>>
end
