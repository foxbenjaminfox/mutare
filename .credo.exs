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
        # `extra:` merges onto the default check set (`enabled:` would *replace* it).
        extra: [
          # The metamutant/coverage helpers are whole modules generated via `quote`,
          # so they're long by nature — and this codebase deliberately carries dense,
          # load-bearing comments inside them. Count code, not commentary.
          {Credo.Check.Refactor.LongQuoteBlocks, [ignore_comments: true]}
        ],
        disabled: [
          {Credo.Check.Refactor.CyclomaticComplexity, []},
          {Credo.Check.Refactor.Nesting, []}
        ]
      }
    }
  ]
}
