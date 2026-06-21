defmodule Mutare.UsesEnvTest do
  # `async: false`: this test temporarily flips the global `Mix.env()`, so it must not run
  # concurrently with anything that reads it.
  use ExUnit.Case, async: false

  alias Mutare.Transform.Uses

  defp directives_at(source) do
    {_ast, acc} =
      source
      |> Sourceror.parse_string!()
      |> Uses.annotate()
      |> Macro.prewalk([], fn
        {:use, meta, _} = node, acc when is_list(meta) -> {node, acc ++ Uses.directives(meta)}
        node, acc -> {node, acc}
      end)

    Enum.map(acc, &Macro.to_string/1)
  end

  test "an env-sensitive `use` is expanded under the sandbox env (:test), not the scan env" do
    source = "defmodule UsesEnvSensitive do\n  use Mutare.Test.EnvSensitiveUsing\nend"

    previous = Mix.env()
    Mix.env(:dev)

    try do
      rendered = directives_at(source)

      # The metamutant compiles/runs under `:test`, so the `:test` branch (`fetch`) is what's
      # actually in scope — even though the scan is (here, forced) `:dev`. Without mirroring we'd
      # harvest the `:dev` branch (`delete`) and mis-resolve later calls.
      assert "import Map, only: [fetch: 2]" in rendered
      refute "import Map, only: [delete: 2]" in rendered
    after
      Mix.env(previous)
    end
  end
end
