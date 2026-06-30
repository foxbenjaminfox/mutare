defmodule Mutare.Report.Html do
  @moduledoc """
  Renders an HTML page that hosts the interactive mutation report.

  Deliberately **not** a bespoke renderer: it embeds the `Mutare.Report.Json`
  document into the official `mutation-test-report-app` web component (loaded
  from a pinned CDN bundle), which renders the file tree, per-file source with
  inline mutant annotations, and the score. The report data is embedded in one
  HTML file you can open or attach to CI.

  Tradeoff: viewing the page fetches the component bundle from unpkg, so it
  needs network access. Vendoring the bundle is a possible later toggle.
  """

  alias Mutare.{Report.Json, Result}

  @bundle "https://www.unpkg.com/mutation-testing-elements@3.8.0/dist/mutation-test-elements.js"

  @doc """
  Render an HTML report. `opts` is forwarded to `Mutare.Report.Json`
  (so `:min_score` sets the thresholds the viewer colours by).
  """
  @spec render([Result.t()], %{optional(String.t()) => String.t()}, keyword()) :: String.t()
  def render(results, sources, opts \\ []) do
    report = results |> Json.render(sources, opts) |> escape_closing_tags()

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1.0" />
      <title>Mutare mutation report</title>
    </head>
    <body>
      <mutation-test-report-app id="report">
        Your browser is loading the mutation report…
      </mutation-test-report-app>
      <script src="#{@bundle}"></script>
      <script>
        document.getElementById("report").report = #{report};
      </script>
    </body>
    </html>
    """
  end

  # A `</script>` sitting inside embedded source would otherwise terminate our
  # inline <script> early. `\/` is a valid JSON string escape, so neutralising
  # `</` keeps the payload both safe to inline and valid JSON.
  defp escape_closing_tags(json), do: String.replace(json, "</", "<\\/")
end
