# Credo configuration. Only deviations from Credo's defaults are listed here;
# every check not mentioned runs with its built-in default. To browse the full
# menu of available (incl. opt-in) checks, run `mix credo gen.config`.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      strict: false,
      checks: %{
        disabled: [
          {Credo.Check.Refactor.CyclomaticComplexity, []},
          {Credo.Check.Refactor.Nesting, []}
        ]
      }
    }
  ]
}
