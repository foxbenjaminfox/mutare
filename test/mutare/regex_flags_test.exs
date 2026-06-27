defmodule Mutare.Mutators.RegexLiteral.FlagsTest do
  # Unit tests of the positional flag-scope tracker that drives anchor-swap mode-gating.
  # The `open/2`/`close/1` stack effects are exercised directly, decoupled from the walk.
  use ExUnit.Case, async: true

  alias Mutare.Mutators.RegexLiteral.Flags

  defp base(chars \\ ~c""), do: Flags.initial(MapSet.new(chars))

  test "active? reads the innermost (here baseline) frame" do
    s = base(~c"m")
    assert Flags.active?(s, ?m)
    refute Flags.active?(s, ?i)
  end

  describe "open/2 classification" do
    test "a plain capturing group pushes a copy and consumes nothing extra" do
      {consumed, rest, s} = Flags.open("abc)", base(~c"m"))
      assert consumed == ""
      assert rest == "abc)"
      assert length(s) == 2
      assert Flags.active?(s, ?m)
    end

    test "a scoped (?i:…) pushes a frame with the flag added" do
      {consumed, rest, s} = Flags.open("?i:abc)", base())
      assert consumed == "?i:"
      assert rest == "abc)"
      assert length(s) == 2
      assert Flags.active?(s, ?i)
    end

    test "a bare (?i) mutates the current frame in place — no push" do
      {consumed, rest, s} = Flags.open("?i)abc", base())
      assert consumed == "?i)"
      assert rest == "abc"
      assert length(s) == 1
      assert Flags.active?(s, ?i)
    end

    test "an unsetting (?-m) removes the flag from the current frame" do
      {_c, _r, s} = Flags.open("?-m)x", base(~c"m"))
      refute Flags.active?(s, ?m)
    end

    test "a combined (?i-m:…) both adds and removes in the pushed frame" do
      {_c, _r, s} = Flags.open("?i-m:x)", base(~c"m"))
      assert Flags.active?(s, ?i)
      refute Flags.active?(s, ?m)
    end

    test "a non-capturing (?:…) pushes a copy with no flag change" do
      {consumed, _r, s} = Flags.open("?:x)", base(~c"m"))
      assert consumed == "?:"
      assert Flags.active?(s, ?m)
    end

    test "lookaround / named / atomic groups are ordinary openers, never flag sets" do
      for opener <- ["?=x)", "?!x)", "?<=x)", "?<!x)", "?<n>x)", "?P<n>x)", "?'n'x)", "?>x)"] do
        {consumed, rest, s} = Flags.open(opener, base())
        assert consumed == "", "#{opener} should not be read as a modifier group"
        assert rest == opener
        assert length(s) == 2
      end
    end

    test "a (?#…) comment is swallowed whole, with no push and no flag change" do
      {consumed, rest, s} = Flags.open("?#a)b", base(~c"m"))
      assert consumed == "?#a)"
      assert rest == "b"
      assert length(s) == 1
      assert Flags.active?(s, ?m)
    end
  end

  describe "close/1" do
    test "pops the innermost frame, restoring the outer flags" do
      {_c, _r, pushed} = Flags.open("?m:x)", base())
      assert Flags.active?(pushed, ?m)
      assert Flags.close(pushed) |> Flags.active?(?m) == false
    end

    test "never pops below the baseline (a stray ) is harmless)" do
      s = base(~c"m")
      assert Flags.close(s) == s
    end
  end

  test "a bare (?m) inside a pushed frame expires when that frame is popped" do
    # models `a((?m)x)y`: enter group, bare-set m, leave group -> m gone
    s = base()
    {_c, _r, in_group} = Flags.open("inner)", s)
    {_c, _r, with_m} = Flags.open("?m)x", in_group)
    assert Flags.active?(with_m, ?m)
    refute Flags.active?(Flags.close(with_m), ?m)
  end
end
