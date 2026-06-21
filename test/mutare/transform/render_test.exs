defmodule Mutare.Transform.RenderTest do
  use ExUnit.Case, async: true

  alias Mutare.Transform.Render

  describe "to_source/1" do
    test "unwraps block-wrapped pair keys into valid list entries" do
      assert Render.to_source([{{:__block__, [format: :keyword], [:foo]}, 1}]) == "[foo: 1]"

      assert Render.to_source([{{:__block__, [], [:foo]}, 1}]) == "[foo: 1]"
      assert Render.to_source([{{:__block__, [line: 1], [:foo]}, 1}]) == "[foo: 1]"

      non_atom_key = {:foo, [], nil}

      assert Render.to_source([{{:__block__, [format: :keyword], [non_atom_key]}, 1}]) ==
               "[{foo, 1}]"

      assert Render.to_source([{{:__block__, [], [non_atom_key]}, 1}]) == "[{foo, 1}]"
    end
  end
end
