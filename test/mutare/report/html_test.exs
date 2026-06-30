defmodule Mutare.Report.HtmlTest do
  use ExUnit.Case, async: true

  alias Mutare.{Report.Html, Result, Site}

  defp result do
    %Result{
      status: :survived,
      site: %Site{
        id: 1,
        file: "lib/a.ex",
        line: 3,
        column: 5,
        range: %{start: [line: 3, column: 5], end: [line: 3, column: 11]},
        mutator: :relational,
        kind: :in_place,
        operation: :replace,
        original_code: "a >= b",
        mutated_code: "a > b"
      }
    }
  end

  # The embedded payload sits between `.report = ` and the statement's `;`.
  defp payload(html) do
    html
    |> String.split(".report = ", parts: 2)
    |> List.last()
    |> String.split(";", parts: 2)
    |> List.first()
  end

  test "produces an HTML document hosting the report web component" do
    html = Html.render([result()], %{"lib/a.ex" => "a >= b"})

    assert html =~ "<!DOCTYPE html>"
    assert html =~ "<mutation-test-report-app"
    assert html =~ "mutation-testing-elements@3.8.0"
    assert html =~ ".report ="
  end

  test "embeds a decodable report-schema JSON payload" do
    html = Html.render([result()], %{"lib/a.ex" => "a >= b"})
    doc = html |> payload() |> JSON.decode!()

    assert doc["schemaVersion"] == "1.0"
    assert doc["files"]["lib/a.ex"]["mutants"] |> hd() |> Map.get("status") == "Survived"
  end

  test "neutralises </ in embedded source so the inline script can't break out, staying valid JSON" do
    html = Html.render([result()], %{"lib/a.ex" => ~s(y = "</script>")})

    assert html =~ "<\\/script>"
    doc = html |> payload() |> JSON.decode!()
    assert doc["files"]["lib/a.ex"]["source"] == ~s(y = "</script>")
  end
end
