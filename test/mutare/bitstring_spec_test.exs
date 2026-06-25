defmodule Mutare.BitstringSpecTest do
  @moduledoc """
  Unicode bitstring-specifier mutation (`Mutare.Mutators.BitstringSpec`): swap a
  `<<…>>` *constructor* segment's text encoding (`utf8 ↔ utf16 ↔ utf32`) and byte
  order (`big ↔ little`, utf16/utf32 only). Never-equivalent, compile-safe, and
  constructor-only — a spec in a pattern (the decoding side) has no selector to
  host it and is left alone. On by default.
  """
  use ExUnit.Case, async: false

  alias Mutare.{Selector, Site}

  @compile {:no_warn_undefined, [Mutare.BitstringSpecFixture]}

  # Isolate the family: with only BitstringSpec enabled, the bitstring values and
  # the surrounding code stay raw, so every site is a spec swap.
  @only [Mutare.Mutators.BitstringSpec]

  defp sites(body) do
    {_meta, sites, _} =
      Mutare.transform_string("defmodule M do\n  def f(cp), do: #{body}\nend\n", mutators: @only)

    sites
  end

  defp mutated_codes(body), do: body |> sites() |> Enum.map(& &1.mutated_code)

  describe "encoding swaps (utf8 ↔ utf16 ↔ utf32)" do
    test "a bare encoding swaps for the other two" do
      # utf8 has no byte order, so just the two encoding swaps; utf32 is multi-byte,
      # so it also earns the added -little (like bare utf16).
      assert mutated_codes("<<cp::utf8>>") == ["<<cp::utf16>>", "<<cp::utf32>>"]

      assert mutated_codes("<<cp::utf32>>") == [
               "<<cp::utf8>>",
               "<<cp::utf16>>",
               "<<cp::utf32-little>>"
             ]
    end

    test "a string-literal segment swaps the same way (the value stays raw)" do
      assert mutated_codes(~s|<<"hi"::utf16>>|) ==
               [~s|<<"hi"::utf8>>|, ~s|<<"hi"::utf32>>|, ~s|<<"hi"::utf16-little>>|]
    end

    test "swapping to utf8 drops a byte-order modifier (utf8 is byte-oriented)" do
      assert "<<cp::utf8>>" in mutated_codes("<<cp::utf16-big>>")
      assert "<<cp::utf8>>" in mutated_codes("<<cp::utf16-little>>")
    end

    test "swapping between utf16/utf32 keeps the byte order, in either written order" do
      assert "<<cp::utf32-little>>" in mutated_codes("<<cp::utf16-little>>")
      assert "<<cp::little-utf16>>" in mutated_codes("<<cp::little-utf32>>")
    end

    test "a (legal but unusual) byte order on a utf8 source rides onto the utf16/32 swaps" do
      # utf8 tolerates an endianness modifier (it ignores it); swapping the encoding
      # keeps the modifier, and utf8 itself gets no byte-order mutant.
      assert mutated_codes("<<cp::utf8-big>>") == ["<<cp::utf16-big>>", "<<cp::utf32-big>>"]
    end
  end

  describe "byte-order swaps (utf16/utf32 only)" do
    test "an implicit big (bare utf16) earns an added -little" do
      assert "<<cp::utf16-little>>" in mutated_codes("<<cp::utf16>>")
    end

    test "an explicit big/little flips to the other" do
      assert "<<cp::utf16-little>>" in mutated_codes("<<cp::utf16-big>>")
      assert "<<cp::utf16-big>>" in mutated_codes("<<cp::utf16-little>>")
    end

    test "utf8 gets no byte-order mutant" do
      assert mutated_codes("<<cp::utf8>>") == ["<<cp::utf16>>", "<<cp::utf32>>"]
    end

    test "native is left untouched as source and target (host-dependent → no equivalent risk)" do
      # Only the two encoding swaps; no byte-order mutant, and native never appears
      # as a target.
      codes = mutated_codes("<<cp::utf16-native>>")
      assert codes == ["<<cp::utf8>>", "<<cp::utf32-native>>"]
      refute Enum.any?(codes, &(&1 =~ "native" and &1 =~ "utf16"))
    end

    test "a literal byte-palindromic codepoint skips the byte-order swap (equivalent)" do
      # `<<0::utf16>>` is `<<0, 0>>` big or little, so the byte-order swap would emit
      # identical bytes — an unkillable equivalent. It is dropped; only the
      # never-equivalent encoding swaps (which change the byte *width*) remain.
      assert mutated_codes("<<0::utf16>>") == ["<<0::utf8>>", "<<0::utf32>>"]
      assert mutated_codes("<<0::utf32>>") == ["<<0::utf8>>", "<<0::utf16>>"]
      # 0x0101 = 257 = <<1, 1>> in utf16 — also palindromic.
      refute Enum.any?(mutated_codes("<<0x0101::utf16>>"), &(&1 =~ "little"))
    end

    test "a literal non-palindromic codepoint keeps the byte-order swap" do
      # 104 = <<0, 104>> big / <<104, 0>> little — observably different.
      assert "<<104::utf16-little>>" in mutated_codes("<<104::utf16>>")
    end

    test "a variable value keeps the byte-order swap (equivalence can't be proven)" do
      assert "<<cp::utf16-little>>" in mutated_codes("<<cp::utf16>>")
    end
  end

  describe "literal-value equivalence (binary strings)" do
    # `<<bin::utf16>>` encodes each codepoint of the string in turn, so a literal
    # string is decidable just like an integer codepoint.
    test "a byte-palindromic string drops the byte-order swap, keeps the encoding swaps" do
      # "\0" → <<0, 0>> in either order: an equivalent byte-order mutant, dropped.
      assert mutated_codes(~S|<<"\0"::utf16>>|) == [~S|<<"\0"::utf8>>|, ~S|<<"\0"::utf32>>|]
    end

    test "an empty string drops every mutant (all widths and orders emit <<>>)" do
      # `<<""::_>>` is `<<>>` under every encoding *and* order, so even the encoding
      # swaps coincide — there is no observable mutant.
      assert mutated_codes(~S|<<""::utf16>>|) == []
      assert mutated_codes(~S|<<""::utf8>>|) == []
    end

    test "a non-palindromic string keeps the byte-order swap" do
      assert ~S|<<"hi"::utf16-little>>| in mutated_codes(~S|<<"hi"::utf16>>|)
    end

    test "an escaped string is decoded before comparing (no phantom survivor)" do
      # `"\0\0"` decodes to <<0, 0>> — utf16 <<0, 0, 0, 0>> in *either* order, an
      # equivalent byte-order swap that must be dropped. Sourceror keeps the source
      # escape un-decoded as `"\\0\\0"` (bytes 92, 48, 92, 48 — *not* palindromic),
      # so reading the node directly would compare the wrong bytes and let the
      # equivalent `-little` mutant survive as a phantom. The filter re-decodes, so
      # it drops; only the never-equivalent (width-changing) encoding swaps remain.
      assert mutated_codes(~S|<<"\0\0"::utf16>>|) == [~S|<<"\0\0"::utf8>>|, ~S|<<"\0\0"::utf32>>|]
    end
  end

  describe "what is not mutated" do
    test "a non-utf segment yields no sites" do
      assert sites("<<cp::integer-big-size(16)>>") == []
      assert sites("<<cp::binary>>") == []
    end

    test "a spec in a function-head pattern is excluded (no selector hosts a pattern)" do
      {_meta, sites, _} =
        Mutare.transform_string(
          "defmodule M do\n  def f(<<cp::utf16>>), do: cp\nend\n",
          mutators: @only
        )

      assert sites == []
    end

    test "a spec on a `=` match LHS (a decode) is excluded" do
      {_meta, sites, _} =
        Mutare.transform_string(
          "defmodule M do\n  def f(bin) do\n    <<cp::utf16>> = bin\n    cp\n  end\nend\n",
          mutators: @only
        )

      assert sites == []
    end

    test "an interpolated string is left to StringLiteral's domain" do
      assert sites(~s|"a\#{cp}b"|) == []
    end
  end

  describe "deprecated parenthesized specifiers (`utf16-big()`)" do
    # The deprecated-but-compiling paren form parses its modifier as a zero-arg
    # call (`{:big, m, []}`, context `[]` not `nil`). If the reader missed it, the
    # segment would look orderless and earn a *second* `-little`, yielding the
    # uncompilable `utf16-big()-little` (conflicting endianness) — a build poison.
    test "a parenthesized order is flipped, never appended-to (no conflicting endianness)" do
      codes = mutated_codes("<<cp::utf16-big()>>")
      assert "<<cp::utf16-little()>>" in codes
      refute Enum.any?(codes, &(&1 =~ "big" and &1 =~ "little"))
    end

    test "a parenthesized native is left alone (no spurious byte-order mutant)" do
      refute Enum.any?(mutated_codes("<<cp::utf16-native()>>"), &(&1 =~ "little"))
    end

    test "every mutant of a parenthesized-spec source still compiles" do
      import ExUnit.CaptureIO

      source = """
      defmodule Mutare.BitstringSpecParenFixture do
        def f(cp), do: <<cp::utf16-big()>>
        def g(cp), do: <<cp::utf16-native()>>
      end
      """

      {metamutant, _sites, _} = Mutare.transform_string(source, mutators: @only)

      # The paren form warns (deprecation); the point is it *compiles*. Before the
      # fix, a `utf16-big()-little` mutant raised CompileError here.
      capture_io(:stderr, fn ->
        assert [_ | _] = Code.compile_string(metamutant)
      end)
    end
  end

  describe "multi-segment" do
    test "only the utf-bearing segment mutates; siblings ride untouched" do
      assert mutated_codes("<<cp, rest::binary, c::utf8>>") ==
               ["<<cp, rest::binary, c::utf16>>", "<<cp, rest::binary, c::utf32>>"]
    end

    test "two utf segments each mutate independently" do
      codes = mutated_codes("<<a::utf8, b::utf16>>")
      assert "<<a::utf16, b::utf16>>" in codes
      assert "<<a::utf32, b::utf16>>" in codes
      assert "<<a::utf8, b::utf8>>" in codes
      assert "<<a::utf8, b::utf32>>" in codes
      assert "<<a::utf8, b::utf16-little>>" in codes
    end
  end

  describe "site metadata" do
    test "each site is an in-place :bitstring_spec replacement" do
      [site | _] = sites("<<cp::utf16>>")
      assert %Site{mutator: :bitstring_spec, kind: :in_place, operation: :replace} = site
      assert site.original_code == "<<cp::utf16>>"
    end

    test "describe/1 renders the whole-node swap" do
      [site | _] = sites("<<cp::utf8>>")
      assert Site.describe(site) == "bitstring_spec  <<cp::utf8>> → <<cp::utf16>>"
    end
  end

  describe "runtime semantics (one compile, flip the selector)" do
    setup do
      source = """
      defmodule Mutare.BitstringSpecFixture do
        def enc(cp), do: <<cp::utf16>>
      end
      """

      {metamutant, sites, _} = Mutare.transform_string(source, mutators: @only)
      Code.compile_string(metamutant)
      Selector.put(Selector.baseline())
      on_exit(fn -> Selector.put(Selector.baseline()) end)

      by_code = Map.new(sites, &{&1.mutated_code, &1.id})
      %{by_code: by_code}
    end

    test "baseline is utf16-big; each mutant emits distinct, expected bytes", %{by_code: by_code} do
      # The metamutant compiles once and the selector picks the active mutant.
      assert Mutare.BitstringSpecFixture.enc(?h) == <<0, 104>>

      Selector.put(by_code["<<cp::utf8>>"])
      assert Mutare.BitstringSpecFixture.enc(?h) == <<104>>

      Selector.put(by_code["<<cp::utf32>>"])
      assert Mutare.BitstringSpecFixture.enc(?h) == <<0, 0, 0, 104>>

      Selector.put(by_code["<<cp::utf16-little>>"])
      assert Mutare.BitstringSpecFixture.enc(?h) == <<104, 0>>
    end
  end
end
