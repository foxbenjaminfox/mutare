# Overlay a generated variant onto a dedicated benchmark working directory,
# preserving unchanged source mtimes and the destination's compiled build.
case System.argv() do
  [source, destination] ->
    source = Path.expand(source)
    destination = Path.expand(destination)
    sources = Path.wildcard(Path.join(source, "lib/**/*.ex"))
    if sources == [], do: raise("no generated sources under #{source}")

    relative = Enum.map(sources, &Path.relative_to(&1, source))

    existing =
      destination
      |> Path.join("lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, destination))

    if existing -- relative != [],
      do: raise("destination has extra source files; use a fresh benchmark directory")

    for rel <- ["mix.exs", "smoke.exs" | relative] do
      content = File.read!(Path.join(source, rel))
      target = Path.join(destination, rel)

      if File.read(target) == {:ok, content} do
        IO.puts("unchanged #{rel}")
      else
        File.mkdir_p!(Path.dirname(target))
        File.write!(target, content)
        IO.puts("changed #{rel}")
      end
    end

  _ ->
    raise "usage: elixir bench/overlay.exs GENERATED_PROJECT WORKING_DIRECTORY"
end
