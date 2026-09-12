defmodule Mutare.Sandbox.RuntimeConfigTest do
  use ExUnit.Case, async: true

  alias Mutare.Sandbox.RuntimeConfig
  alias Mutare.Test.Project

  test "wrapped configuration preserves bindings, imports, and relative config paths" do
    %{project: root} =
      Project.build(:config_wrapper, %{
        "conf/runtime.exs" => """
        import Config
        alias Elixir.String, as: Text
        value = Text.upcase("configured")
        import_config "extra.exs"
        config :config_wrapper, value: value, directory: __DIR__
        """,
        "conf/extra.exs" => "import Config\nconfig :config_wrapper, extra: true\n"
      })

    assert %{"conf/runtime.exs" => wrapped} = RuntimeConfig.files(root, [])
    path = Path.join(root, "conf/runtime.exs")
    File.write!(path, wrapped)

    assert Config.Reader.read!(path) == [
             config_wrapper: [extra: true, value: "CONFIGURED", directory: Path.dirname(path)]
           ]
  end

  test "discovery skips dependencies, excluded trees, and symlinks" do
    %{project: root} =
      Project.build(:config_discovery, %{
        "conf/runtime.exs" => "import Config\n",
        "deps/example/config/runtime.exs" => "import Config\n",
        "_build/runtime.exs" => "import Config\n"
      })

    File.mkdir_p!(Path.join(root, "linked_file"))
    File.ln_s!("../conf/runtime.exs", Path.join(root, "linked_file/runtime.exs"))
    File.ln_s!("conf", Path.join(root, "linked_dir"))

    assert %{"conf/runtime.exs" => _} = RuntimeConfig.files(root, ["_build"])
    assert map_size(RuntimeConfig.files(root, ["_build"])) == 1
  end
end
