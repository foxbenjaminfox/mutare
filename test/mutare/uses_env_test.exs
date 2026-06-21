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

      # The swap restored the original env.
      assert Mix.env() == :dev
    after
      Mix.env(previous)
    end
  end

  test "concurrent transforms in a non-sandbox env don't corrupt the global Mix env" do
    source = "defmodule UsesSlow do\n  use Mutare.Test.SlowUsing\nend"

    previous = Mix.env()
    Mix.env(:dev)

    try do
      # Many overlapping expansions (each sleeps): a non-serialized mirror would interleave its
      # save/restore — one capturing another's transient `:test` and leaving the VM at `:test`.
      results =
        1..8
        |> Enum.map(fn _ -> Task.async(fn -> directives_at(source) end) end)
        |> Enum.map(&Task.await(&1, 10_000))

      assert Enum.all?(results, &("import Map, only: [fetch: 2]" in &1))
      # Serialized swaps each restore the true previous env, so the VM is left as we set it.
      assert Mix.env() == :dev
    after
      Mix.env(previous)
    end
  end
end
