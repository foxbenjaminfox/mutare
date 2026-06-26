defmodule Mutare.Transform.CallsTest do
  use ExUnit.Case, async: true

  alias Mutare.Transform.Calls

  doctest Mutare.Transform.Calls

  describe "resolved_call/1 — a `:qualify` rebuild over an Erlang-atom module" do
    test "a renamed sibling is requalified with the Erlang atom module, a same-name swap stays bare" do
      # A bare call stamped as imported from an Erlang atom module under a *selective* import
      # (`:qualify`). The stamp is what `Mutare.Transform.Resolve` writes; here we set it directly
      # to drive the rebuild's Erlang-atom `qualifier/1` branch.
      arg = {:x, [], nil}
      node = {:reverse, [mutare_import: {:binary, :qualify}], [arg]}

      assert {:binary, :reverse, [^arg], rebuild} = Calls.resolved_call(node)

      # Same name + arity → left bare (the value-only/no-op path).
      assert {:reverse, _meta, [^arg]} = rebuild.(:reverse, [arg])

      # A rename requalifies through the Erlang atom module (never alias-expanded).
      assert {{:., [], [{:__block__, [], [:binary]}, :part]}, _meta, [^arg]} =
               rebuild.(:part, [arg])
    end
  end
end
