defmodule Mutare.UsesNoMixTest do
  use ExUnit.Case, async: true

  # Spawns a bare `elixir` subprocess (no `mix`), so it's slow-ish — excluded from the fast loop.
  @moduletag :runner

  # `Mutare.Transform.Uses` mirrors the sandbox's `Mix.env()` while expanding `use`. The public
  # `transform_string/2` API may be embedded in a plain Elixir process that never started Mix,
  # where `Mix.env/0` *raises* — so the mirror must degrade rather than break the library.
  test "transform_string works in a process where Mix was never started" do
    build_lib = Path.join(Mix.Project.build_path(), "lib")

    code = ~S"""
    if Process.whereis(Mix.State), do: raise("expected Mix to be unstarted in this subprocess")
    {_meta, sites, _next} = Mutare.Transform.transform_string_with_sites("defmodule M do\n  def f(a, b), do: a - b\nend")
    IO.write("SITES=#{length(sites)}")
    """

    {out, status} =
      System.cmd("elixir", ["-e", code],
        env: [{"ERL_LIBS", build_lib}],
        stderr_to_stdout: true
      )

    assert status == 0, "transform_string crashed in a Mix-less process:\n#{out}"
    assert out =~ ~r/SITES=[1-9]/
  end
end
