defmodule Mutare.Transform.NamesTest do
  use ExUnit.Case, async: true

  alias Mutare.Coverage.Recorder
  alias Mutare.Transform.Names

  # Build an AST that "mentions" each given atom as a bare variable, so that
  # `generated_names/1`'s identifier scan collects them all into its taken set.
  defp source_using(names) do
    names
    |> Enum.map_join("\n", &Atom.to_string/1)
    |> Code.string_to_quoted!()
  end

  describe "generated_names/1 dispatch-variable salting" do
    test "is the canonical name when the source never mentions it" do
      %{active_var: active} = Names.generated_names(source_using([:x, :y]))

      assert active == Recorder.var_name()
    end

    test "falls back through canonical_0, canonical_1, … on successive collisions" do
      canonical = Recorder.var_name()
      zero = :"#{canonical}_0"
      one = :"#{canonical}_1"

      # Only the canonical name is taken → the first numbered fallback (`_0`).
      %{active_var: active1} = Names.generated_names(source_using([canonical]))
      assert active1 == zero

      # The canonical name AND its `_0` fallback are both taken → the *next* in the
      # documented sequence, `_1`. This pins the +1 increment of the fallback stream:
      # the second candidate must be `_1` (not `_0` again — which would loop forever —
      # nor `_2`, which would skip the documented sequence).
      %{active_var: active2} = Names.generated_names(source_using([canonical, zero]))
      assert active2 == one
    end
  end

  describe "generated_names/1 private-prefix salting" do
    test "is the canonical `__mutare_` prefix when no source name begins with it" do
      %{prefix: prefix} = Names.generated_names(source_using([:x, :y]))
      assert prefix == "__mutare_"
    end

    test "falls back through __mutare_0_, __mutare_1_, … on successive prefix collisions" do
      # One identifier under the canonical prefix → the first numbered prefix.
      %{prefix: prefix1} = Names.generated_names(source_using([:__mutare_foo]))
      assert prefix1 == "__mutare_0_"

      # An identifier under `__mutare_` *and* one under `__mutare_0_` → the *next*
      # prefix, `__mutare_1_`. Pins the +1 increment of the prefix-candidate stream
      # exactly as the dispatch-variable sequence above.
      %{prefix: prefix2} =
        Names.generated_names(source_using([:__mutare_foo, :__mutare_0_bar]))

      assert prefix2 == "__mutare_1_"
    end
  end

  describe "generated_names/1 collects def-like names" do
    # A generated private `defp __mutare_…` could duplicate a hand-written def-like
    # name, so every def/defp/defmacro/… head's name is collected into the taken set.
    # Each source below names a function under the canonical `__mutare_` prefix, so a
    # correctly-collected name forces the prefix to salt to `__mutare_0_`; a missed
    # name leaves it `__mutare_`.

    test "from a plain def head" do
      %{prefix: prefix} =
        Names.generated_names(Code.string_to_quoted!("def __mutare_foo(x), do: x"))

      assert prefix == "__mutare_0_"
    end

    test "from a guarded def head (the `{:when, _, …}` clause)" do
      # The head is `{:when, _, [call | guards]}`; the name lives in `call`, so
      # `def_name/1` must recurse through the `when`. Dropping that clause would
      # mis-collect the atom `:when` and leave `__mutare_guarded` unseen.
      %{prefix: prefix} =
        Names.generated_names(Code.string_to_quoted!("def __mutare_guarded(x) when x > 0, do: x"))

      assert prefix == "__mutare_0_"
    end

    test "from a defmacro head" do
      %{prefix: prefix} =
        Names.generated_names(Code.string_to_quoted!("defmacro __mutare_mac(x), do: x"))

      assert prefix == "__mutare_0_"
    end
  end

  describe "salted_name?/2 (the inverse of the salting convention)" do
    test "true for the canonical name itself" do
      assert Names.salted_name?(:mutare_active, :mutare_active)
    end

    test "true for a `<canonical>_<int>` salted name" do
      assert Names.salted_name?(:mutare_active, :mutare_active_0)
      assert Names.salted_name?(:mutare_active, :mutare_active_42)
    end

    test "false for an unrelated name, or a non-integer / empty suffix" do
      refute Names.salted_name?(:mutare_active, :some_user_var)
      refute Names.salted_name?(:mutare_active, :mutare_active_x)
      refute Names.salted_name?(:mutare_active, :mutare_active_)
    end
  end
end
