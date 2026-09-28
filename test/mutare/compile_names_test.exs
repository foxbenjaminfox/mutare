defmodule Mutare.Test.Compile.NamesTest do
  use ExUnit.Case, async: true

  alias Mutare.Test.Compile
  alias Mutare.Test.Compile.Names

  test "a module execution may compile its own fixture name again" do
    name = Module.concat(__MODULE__, Repeated)
    source = "defmodule #{inspect(name)} do\n  def f, do: 1\nend\n"

    assert [{^name, _}] = Compile.string(source)
    assert [{^name, _}] = Compile.string(source)
  end

  test "a name another execution claimed is refused before compiling" do
    name = Module.concat(__MODULE__, Foreign)
    Names.claim!([])
    :ets.insert(Names, {name, {Mutare.SomeOtherTest, self()}})

    message =
      assert_raise ArgumentError, fn ->
        Compile.string("defmodule #{inspect(name)} do\nend\n")
      end

    assert Exception.message(message) =~ "Mutare.SomeOtherTest"
    refute Code.loaded?(name)
  end

  test "a module compiled into the test build is never redefined" do
    assert_raise ArgumentError, ~r/compiled into the test build/, fn ->
      Compile.string("defmodule Mutare.Test.Compile do\nend\n")
    end
  end
end
