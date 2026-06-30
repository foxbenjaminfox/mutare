defmodule Mutare.Mutators.BitstringSpec do
  @moduledoc """
  Mutates Unicode encoding and byte-order specifiers in bitstring constructors.
  Each mutant changes one segment along one of these axes.

  ## Encoding

  A segment using `utf8`, `utf16`, or `utf32` receives replacements using each of
  the other encodings. These encodings accept the same Unicode scalar values but
  produce different byte widths for non-empty values.

  ## Byte order

  `big` and `little` are exchanged for `utf16` and `utf32` segments. A bare UTF-16
  or UTF-32 specifier defaults to big-endian and receives a variant with `little`
  added. UTF-8 has no byte-order mutation. `native` is not used as a source or
  replacement because its result depends on the host architecture.

  For literal integer and binary values, each candidate is encoded before emission.
  A candidate whose bytes equal the original is removed. This filters empty values
  and byte-palindromic values whose byte order is unobservable. Variable values
  remain eligible because some runtime input can distinguish the encodings.

  The family applies only to runtime bitstring constructors. Bitstring patterns are
  not mutated because an in-place selector cannot wrap a pattern. Interpolated
  strings and segments without a UTF encoding are also excluded. UTF segments with
  `size` or `unit` specifiers are not valid targets. Segment values may still be
  mutated independently by other families.
  """
  @behaviour Mutare.Mutator

  alias Mutare.AST

  # The three Unicode codepoint encodings, mutually swappable.
  @encodings [:utf8, :utf16, :utf32]

  # The architecture-independent byte orders. `:native` is deliberately absent —
  # it resolves to the host endianness, so mutating to/from it risks an
  # equivalent-on-this-host mutant (see the moduledoc).
  @byte_orders [:big, :little]

  @impl Mutare.Mutator
  def name, do: :bitstring_spec

  @impl Mutare.Mutator
  def mutate({:<<>>, meta, segments} = node)
      when is_list(meta) and is_list(segments) and segments != [] do
    # A `:delimiter` marks an interpolated string (a `<<>>` written as `"…"`); its
    # segments are `::binary`, never utf — leave it to StringLiteral's domain.
    if AST.string_binary?(node) do
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
  # bare value) or one whose spec has no utf encoding yields none. When the value
  # is a **literal** (an integer codepoint or a binary string) we drop any variant
  # whose encoded bytes equal the original's — an unkillable equivalent (see
  # `reject_equivalent/3`).
  defp spec_variants({:"::", smeta, [value, spec]}) do
    case find_atom(spec, @encodings) do
      nil ->
        []

      enc ->
        (encoding_variants(spec, enc) ++ order_variants(spec, enc))
        |> Enum.map(&{:"::", smeta, [value, &1]})
        |> reject_equivalent(value, spec)
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
  # order, so it gets none. (A swap that proves equivalent for a literal value —
  # a byte-palindromic codepoint — is dropped later by `reject_equivalent/3`.)
  defp order_variants(_spec, :utf8), do: []

  defp order_variants(spec, _enc) do
    case find_atom(spec, [:native | @byte_orders]) do
      :big -> [replace_atom(spec, :big, :little)]
      :little -> [replace_atom(spec, :little, :big)]
      :native -> []
      nil -> [append_atom(spec, :little)]
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

  # --- literal-value equivalence ---------------------------------------------
  #
  # A spec swap is observable only when it changes the bytes the segment emits.
  # For a **literal** value — an integer codepoint or a binary string, whose utf
  # encoding is each codepoint encoded in turn — we decide that statically: encode
  # the original and each variant, and drop any variant whose bytes match. This
  # covers both axes' equivalent cases:
  #
  #   * **byte order** — a byte-palindromic value reads the same in either order
  #     (`<<0::utf16>>` and `<<"\0"::utf16>>` are `<<0, 0>>`; `<<0x0101::utf16>>`
  #     is `<<1, 1>>`), so its `big`/`little` swap is a no-op;
  #   * **encoding** — an **empty** value is `<<>>` under every width
  #     (`<<""::utf16>>`), so its encoding swaps coincide too.
  #
  # A non-literal value (a variable) can't be decided, so all variants are kept —
  # each is killable by some input, so it is a real mutant, not an equivalent one.
  defp reject_equivalent(variants, value, original_spec) do
    with {:ok, decoded} <- decoded_value(value),
         points when is_list(points) <- codepoints(decoded),
         {:ok, original_bytes} <- spec_bytes(points, original_spec) do
      Enum.reject(variants, fn {:"::", _, [_, spec]} ->
        spec_bytes(points, spec) == {:ok, original_bytes}
      end)
    else
      _ -> variants
    end
  end

  # The bytes `<<value::spec>>` emits, given the value's already-decoded codepoints,
  # or `:error` when the spec carries no encoding or a codepoint can't be encoded
  # (a surrogate / over-max raises) — in which case the variant is kept, not
  # guessed at. `little` is the only order that changes the bytes; everything else
  # (explicit/implicit `big`, host-dependent `native`) is encoded big-endian, since
  # native's sole equivalence is the order-independent empty case (kept deterministic).
  defp spec_bytes(points, spec) do
    case find_atom(spec, @encodings) do
      nil ->
        :error

      enc ->
        order = if find_atom(spec, [:little]) == :little, do: :little, else: :big
        encode_all(points, enc, order)
    end
  end

  # The **semantic** literal value (integer or binary), or `:error` if not a
  # literal. Sourceror preserves a string's source *escapes* un-decoded — `"\0"`
  # stays the two-byte `"\\0"`, not the NUL the compiler emits — so reading the
  # node directly would compare the wrong bytes and let an **equivalent** mutant
  # survive as a phantom: the un-decoded `"\\0"` looks non-palindromic, so its
  # byte-order swap wouldn't be dropped, even though `<<"\0"::utf16>>` is `<<0, 0>>`
  # in either order. (The reverse — a real mutant *false-dropped* — can't happen:
  # an escaped value carries a backslash, which is never byte-palindromic, so an
  # un-decoded comparison only ever *under*-drops.) We render the literal back to
  # source and re-parse with the standard (escape-decoding) parser to recover what
  # the compiler will actually encode.
  defp decoded_value(value) do
    with {:ok, _literal} <- AST.literal_value(value),
         {:ok, decoded} <- Code.string_to_quoted(AST.to_string(value)),
         true <- is_integer(decoded) or is_binary(decoded) do
      {:ok, decoded}
    else
      _ -> :error
    end
  end

  # The Unicode codepoints of a literal value: a bare integer is one codepoint; a
  # binary string is its codepoints in order. Anything else (an invalid-UTF-8
  # binary, a float) is not a utf value we can encode.
  defp codepoints(value) when is_integer(value), do: [value]

  defp codepoints(value) when is_binary(value) do
    String.to_charlist(value)
  rescue
    _ -> :error
  end

  defp codepoints(_value), do: :error

  defp encode_all(points, enc, order) do
    {:ok, points |> Enum.map(&encode(&1, enc, order)) |> IO.iodata_to_binary()}
  rescue
    ArgumentError -> :error
  end

  defp encode(cp, :utf8, _order), do: <<cp::utf8>>
  defp encode(cp, :utf16, :big), do: <<cp::utf16-big>>
  defp encode(cp, :utf16, :little), do: <<cp::utf16-little>>
  defp encode(cp, :utf32, :big), do: <<cp::utf32-big>>
  defp encode(cp, :utf32, :little), do: <<cp::utf32-little>>
end
