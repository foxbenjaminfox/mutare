# Why does a function miss the clean path? Transform every source under the given
# roots with the variant threshold lowered to one, and tabulate what the emitter decided
# for each candidate region. Run with `mix run bench/clean_eligibility.exs ROOT...`.
# See bench/README.md, "Clean-path eligibility".

defmodule Mutare.CleanEligibilityBench do
  alias Mutare.Transform.CleanRegion.Decision

  def run(roots) do
    files = Enum.flat_map(roots, &Path.wildcard(Path.join(&1, "**/*.ex")))

    {decisions, failed} =
      files
      |> Task.async_stream(&decisions/1, timeout: :infinity, ordered: false)
      |> Enum.reduce({[], []}, fn
        {:ok, {:ok, decisions}}, {all, failed} -> {decisions ++ all, failed}
        {:ok, {:error, file}}, {all, failed} -> {all, [file | failed]}
      end)

    IO.puts(
      "#{length(files)} files, #{length(failed)} unparsable, #{length(decisions)} regions\n"
    )

    for delivery <- [:lifted, :in_place] do
      regions = Enum.filter(decisions, &(&1.delivery == delivery))
      variants = regions |> Enum.map(& &1.variants) |> Enum.sum()
      IO.puts("== #{delivery}: #{length(regions)} regions, #{variants} emitted variants")

      for {label, members} <- Enum.group_by(regions, &outcome/1) |> Enum.sort() do
        share = members |> Enum.map(& &1.variants) |> Enum.sum()

        IO.puts(
          "   #{String.pad_trailing(to_string(label), 12)} #{pad(length(members))} regions " <>
            "#{percent(length(members), length(regions))}   #{pad(share)} variants #{percent(share, variants)}"
        )
      end

      IO.puts("")
    end

    IO.puts("== selector sites per region (all regions)")

    for {bucket, members} <- decisions |> Enum.group_by(&bucket(&1.sites)) |> Enum.sort() do
      clean = Enum.count(members, &(not match?({:ineligible, _reason}, &1.verdict)))
      share = members |> Enum.map(& &1.variants) |> Enum.sum()

      IO.puts(
        "   #{String.pad_trailing(bucket_label(bucket), 8)} #{pad(length(members))} regions, " <>
          "#{pad(clean)} eligible, #{pad(share)} variants"
      )
    end

    IO.puts("\n== rejection reasons (regions, variants)")

    decisions
    |> Enum.flat_map(fn
      %Decision{verdict: {:ineligible, reason}} = decision -> [{reason, decision.variants}]
      _eligible -> []
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {reason, variants} -> {reason, length(variants), Enum.sum(variants)} end)
    |> Enum.sort_by(fn {_reason, regions, _variants} -> -regions end)
    |> Enum.take(60)
    |> Enum.each(fn {reason, regions, variants} ->
      IO.puts("   #{pad(regions)} #{pad(variants)}  #{inspect(reason)}")
    end)

    # CLEAN_WHERE='{:call, {:->, 2}}' lists the regions refused for one reason.
    with where when is_binary(where) <- System.get_env("CLEAN_WHERE") do
      IO.puts("\n== regions refused for #{where}")

      for %{verdict: {:ineligible, reason}} = decision <- decisions, inspect(reason) == where do
        {name, arity} = decision.function
        IO.puts("   #{decision.file}:#{decision.line} #{name}/#{arity} (#{decision.delivery})")
      end
    end
  end

  defp decisions(file) do
    result =
      Mutare.Transform.transform_string_with_sites(File.read!(file),
        file: file,
        runtime_namespace: file,
        clean_threshold: 1,
        render_site_code: false,
        warnings: false
      )

    {:ok, Enum.map(result.clean_decisions, &Map.put(&1, :file, file))}
  rescue
    _error -> {:error, file}
  end

  defp outcome(%Decision{verdict: {:ineligible, _reason}}), do: :ineligible
  defp outcome(%Decision{verdict: verdict}), do: verdict

  defp bucket(sites) when sites <= 1, do: 1
  defp bucket(sites) when sites <= 3, do: 3
  defp bucket(sites) when sites <= 7, do: 7
  defp bucket(sites) when sites <= 15, do: 15
  defp bucket(sites) when sites <= 31, do: 31
  defp bucket(_sites), do: :more

  defp bucket_label(1), do: "1"
  defp bucket_label(3), do: "2-3"
  defp bucket_label(7), do: "4-7"
  defp bucket_label(15), do: "8-15"
  defp bucket_label(31), do: "16-31"
  defp bucket_label(:more), do: "32+"

  defp pad(number), do: String.pad_leading(to_string(number), 6)
  defp percent(_part, 0), do: "   -  "
  defp percent(part, whole), do: String.pad_leading("#{round(100 * part / whole)}%", 5)
end

case System.argv() do
  [] -> raise("usage: mix run bench/clean_eligibility.exs ROOT...")
  roots -> Mutare.CleanEligibilityBench.run(roots)
end
