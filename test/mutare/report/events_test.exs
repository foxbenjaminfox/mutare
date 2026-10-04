defmodule Mutare.Report.EventsTest do
  use ExUnit.Case, async: true

  alias Mutare.{Result, Schema, Site, Transform}
  alias Mutare.Report.Events

  # Multi-line on purpose: a pipe whose stage removal rewrites the whole pipe, a multi-line
  # `case` a replacement is re-indented into, and function clauses a clause drop deletes.
  @source """
  defmodule Shop do
    def total(items, rate) do
      items
      |> Enum.map(&(&1.price * &1.qty))
      |> Enum.filter(fn x ->
        x > 0
      end)
      |> Enum.sum()
      |> Kernel.*(1 + rate)
    end

    def label(n) do
      case n do
        0 -> "none"
        n when n > 9 -> "many"
        _ -> "some"
      end
    end

    def sign(0), do: :zero
    def sign(n) when n > 0, do: :positive
    def sign(_), do: :negative
  end
  """

  defp sites, do: Transform.transform_string_with_sites(@source, file: "lib/shop.ex").sites

  defp decode(event), do: event |> Events.encode(0) |> IO.iodata_to_binary() |> JSON.decode!()

  test "a mutant's original is the source in its range, and its replacement patches it as the report does" do
    sites = sites()
    assert length(sites) > 10

    # The patch re-indents a multi-line replacement (the `Enum.filter` stage's swap), so the text
    # it splices is not the site's `mutated_code`: the case the event must read off the patch.
    assert Enum.any?(sites, fn site ->
             Events.mutant(%Result{site: site, status: :killed}, @source, 1).replacement !=
               site.mutated_code
           end)

    for site <- sites do
      event = decode(Events.mutant(%Result{site: site, status: :survived}, @source, 1))
      %{"start" => start, "end" => stop} = event["range"]
      {before, _rest} = split_at(@source, start["line"], start["column"])
      {_upto, after_range} = split_at(@source, stop["line"], stop["column"])

      assert before <> event["original"] <> after_range == @source, describe(site)

      assert before <> event["replacement"] <> after_range == Mutare.Report.patch(site, @source),
             describe(site)
    end
  end

  test "a range's columns count graphemes" do
    # `é` is two bytes, and `👍🏽` two code points but one grapheme: a column counted in bytes or
    # code points would land past the `a + b` it names.
    source = """
    defmodule Mark do
      def f(a, b), do: {"é👍🏽", a + b}
    end
    """

    [site | _] =
      source
      |> Transform.transform_string_with_sites(file: "lib/mark.ex")
      |> Map.fetch!(:sites)
      |> Enum.filter(&(&1.mutator == :arithmetic))

    event = decode(Events.mutant(%Result{site: site, status: :survived}, source, 1))
    assert event["original"] == "a + b"
    assert event["range"]["start"] == %{"line" => 2, "column" => 27}
    assert event["column"] == 27

    {before, _rest} = split_at(source, 2, event["range"]["start"]["column"])
    assert String.ends_with?(before, ~s({"é👍🏽", ))
  end

  test "a deletion's replacement is empty" do
    site = Enum.find(sites(), &(&1.operation == :delete))
    assert site, "the fixture has no deletion"

    assert %{"replacement" => "", "original" => original} =
             decode(Events.mutant(%Result{site: site, status: :killed}, @source, 1))

    assert original =~ "def sign"
  end

  test "a mutant event carries the location the report prints, and omits what it lacks" do
    site = hd(sites())

    event =
      decode(
        Events.mutant(
          %Result{site: site, status: :killed, duration_ms: 12, selection: :tests},
          @source,
          4
        )
      )

    assert %{
             "event" => "mutant",
             "evaluated" => 4,
             "id" => id,
             "file" => "lib/shop.ex",
             "line" => line,
             "column" => column,
             "mutator" => mutator,
             "variant" => variant,
             "status" => "killed",
             "duration_ms" => 12,
             "selection" => "tests",
             "elapsed_ms" => 0
           } = event

    assert {id, line, column, mutator, variant} ==
             {site.id, site.line, site.column, to_string(site.mutator), site.variant}

    # As the runner records a mutant that launched no run: a zero duration and no selection.
    for status <- [:no_coverage, :poisoned] do
      bare =
        decode(Events.mutant(%Result{site: site, status: status, duration_ms: 0}, @source, 1))

      refute Enum.any?(~w(duration_ms selection note reason), &Map.has_key?(bare, &1))
    end
  end

  test "an ignored mutant gives its reason" do
    site = %{hd(sites()) | ignored: true, ignore_reason: "lookup table"}

    assert %{"status" => "ignored", "reason" => "lookup table"} =
             decode(
               Events.mutant(%Result{site: site, status: :ignored, duration_ms: 0}, @source, 1)
             )
  end

  test "the phases a reader can act on become events; detail events do not" do
    assert decode(Events.phase(:compiling)) == %{
             "event" => "phase",
             "phase" => "compiling",
             "elapsed_ms" => 0
           }

    assert %{"phase" => "running", "mutants" => 7} = decode(Events.phase({:running, 7}))

    assert %{"phase" => "confirming_timeouts", "mutants" => 2} =
             decode(Events.phase({:confirming_timeouts, 2}))

    assert %{"phase" => "checking_partitions", "partitions" => 3} =
             decode(Events.phase({:checking_partitions, 3}))

    assert Events.phase({:compiled, 100}) == nil
    assert Events.phase({:run_config, %{}}) == nil
  end

  test "finish counts every status, zeros included, and scores what was evaluated" do
    event = decode(Events.finish(:max_survivors, 10, %{killed: 1, survived: 2}))

    assert %{
             "event" => "finish",
             "stopped" => "max_survivors",
             "mutants" => 10,
             "evaluated" => 3,
             "score" => 33.3
           } =
             event

    assert event["counts"] ==
             Map.new(Mutare.Result.Status.names(), &{to_string(&1), 0})
             |> Map.merge(%{"killed" => 1, "survived" => 2})
  end

  test "an error finish names the reason and carries the message" do
    assert decode(Events.error(:baseline_failed, "baseline suite is not green")) ==
             %{
               "event" => "finish",
               "stopped" => "error",
               "error" => "baseline_failed",
               "message" => "baseline suite is not green",
               "elapsed_ms" => 0
             }
  end

  test "scanned counts the mutants the run will test and their files" do
    schema = %Schema{sites: sites(), metamutants: %{"lib/shop.ex" => ""}}
    assert %{"event" => "scanned", "mutants" => n, "files" => 1} = decode(Events.scanned(schema))
    assert n == Schema.count(schema)
  end

  test "each event encodes as one line" do
    site = Enum.find(sites(), &String.contains?(&1.mutated_code || "", "\n")) || hd(sites())

    line =
      site
      |> then(&Events.mutant(%Result{site: &1, status: :killed}, @source, 1))
      |> Events.encode(5)
      |> IO.iodata_to_binary()

    assert [_one, ""] = String.split(line, "\n")
  end

  # The source before 1-based `line:column`, and the rest from there.
  defp split_at(source, line, column) do
    lines = String.split(source, "\n")
    {head, [current | rest]} = Enum.split(lines, line - 1)
    {prefix, suffix} = String.split_at(current, column - 1)
    before = Enum.map_join(head, &(&1 <> "\n")) <> prefix
    {before, Enum.join([suffix | rest], "\n")}
  end

  defp describe(%Site{} = site),
    do: "mutant #{site.id} (#{site.mutator}) at #{Site.position(site)}"
end
