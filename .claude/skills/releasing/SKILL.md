---
name: releasing
description: >-
  Use when cutting an incremental release of Mutare to Hex — bumping the version,
  updating the changelog, tagging, pushing the tag, waiting for CI, and running
  `mix hex.publish`. Triggers: "release vX.Y.Z", "cut a release", "publish a new
  version", "bump the version and ship". Covers a follow-on release of an already
  published package (the first release, the Hex account, and the licence are done);
  also covers releasing a companion package against a fresh core.
---

# Releasing a new version of Mutare

Scope: **an incremental release** of an already-published package. One source of
truth drives the version — `@version` in `mix.exs` (line ~4) — and it feeds both
`version:` and `docs.source_ref: "v#{@version}"`. Get the tag name and that
constant to agree, or hexdocs source links 404.

## Pick the bump (SemVer)

Pre-1.0, this project treats the **minor** as the breaking slot:

| Change | Bump |
| --- | --- |
| Bug fix, doc fix, new mutator that's on-by-default but compile-safe | **patch** `0.1.0 → 0.1.1` |
| New config option / CLI flag / reporter; new opt-in behaviour | **minor** `0.1.x → 0.2.0` |
| Breaking change to `.mutare.exs`, the mutator/extension capability contracts, CLI semantics, or the result-status set | **minor** (pre-1.0) `0.x → 0.(x+1).0` — lead the changelog entry with it |

When unsure whether something is breaking for **custom mutators / extensions**, treat
the public behaviours (`Mutare.Mutator`, `Mutare.Mutator.Structural`,
`Mutare.Mutator.MacroHost`, `Mutare.CallRouting`, `Mutare.UseExpansion`) and the
published test support (`Mutare.Test`, `Mutare.Test.RoutingExtension`, `Mutare.AST`,
`Mutare.Calls`) as the API surface and bump accordingly. Companion packages are **not**
part of this decision — they version independently (see the last section).

## Steps

Run these on a clean `master` with nothing uncommitted. `origin` is GitHub
(`foxbenjaminfox/mutare` — the repo behind `source_url`, CI, and every changelog link.)

1. **Pre-flight — be green before you touch anything.** The pre-commit hook and CI
   run `mix compile --warnings-as-errors` + `mix check`, but neither runs the slow
   subprocess suite nor validates moduledoc autolinks. Do both yourself:
   ```
   mix test                 # FULL suite incl. :runner + :property (~8 min) — not the fast loop
   mix check                # format-check + credo + dialyzer
   mix docs                 # the ONLY check of @moduledoc/changelog autolinks; must be warning-free
   ```
   Local Elixir is one point of the CI matrix (`~> 1.18` ⇒ 1.18–1.20 × OTP 25–28).
   Anything that touches ExUnit-output parsing in the runner tests or trips the newer
   type checker can pass here and fail there — CI on the pushed tag is the real gate
   (step 7). To reproduce another line locally without a version manager: unzip a
   precompiled build (`github.com/elixir-lang/elixir/releases/download/vX.Y.Z/elixir-otp-NN.zip`,
   NN = your OTP major) under `/tmp`, then run with `PATH=/tmp/elixir-X.Y.Z/bin:$PATH
   MIX_BUILD_ROOT=/tmp/mutare-build-X.Y MIX_HOME=/tmp/mix-X.Y` so it never touches the
   real `_build`.

2. **Bump `@version`** in `mix.exs` (the `@version "X.Y.Z"` line). That is the only
   code change a **patch** release needs — `source_ref` follows automatically.

3. **Update `CHANGELOG.md`** (Keep a Changelog format):
   - Rename the `## [Unreleased]` heading to `## [X.Y.Z] - YYYY-MM-DD` (today's date).
   - Add a fresh empty `## [Unreleased]` section above it.
   - Fill the entry under `### Added` / `### Changed` / `### Fixed` / `### Removed`
     / `### Deprecated` (omit empty groups). Write for *users* — what changed in
     behaviour/config/CLI, not the commit log. A breaking change leads the entry.
     Verify every claim against the code (flag names in `Options.Registry` and the
     `mix mutare` moduledoc, not memory — 0.1.0's draft had four wrong ones).
   - Update the link refs at the **bottom** of the file: point `[Unreleased]` at
     `compare/vX.Y.Z...HEAD`, and add `[X.Y.Z]: …/compare/vPREV...vX.Y.Z`.

4. **Verify the package contents** before committing — confirm `CHANGELOG.md`,
   `README.md`, `LICENSE`, and `lib/` are present and `examples/`, `guides/`, `test/`
   are **not** (the guide reaches hexdocs through `docs.extras`, not the tarball):
   ```
   mix hex.build         # prints the file list and the new version; the .tar is gitignored
   ```

5. **Commit.** `git commit -am "Release vX.Y.Z"`. The pre-commit hook re-runs
   compile + check (several minutes — dialyzer).

6. **Tag — annotated, name must equal `v#{@version}` exactly:**
   ```
   git tag -a vX.Y.Z -m "vX.Y.Z"
   ```
   Annotated, not lightweight: it records who/when, `git describe` sees it, and GitHub
   shows it as a release-grade tag. A tag that doesn't match `@version` breaks every
   hexdocs "source" link and the changelog's compare link.

7. **Push, then wait for CI.** The tag **must** be pushed or every hexdocs "source"
   link 404s. Push commit and tag together, then watch the run on that commit:
   ```
   git push origin master vX.Y.Z
   gh run list --commit $(git rev-parse vX.Y.Z^{commit}) --json databaseId -q '.[0].databaseId' | xargs gh run watch
   ```
   The run is green when `mix check` and the five blocking `test (Elixir …)` rows pass.
   The `test (Elixir main / OTP 28)` row is `continue-on-error` — an early warning for
   the next Elixir, never a gate. Don't publish on a red run: a published version is
   effectively immutable (`mix hex.publish --revert` only works within a short window).

8. **Publish to Hex** (package *and* docs in one go). Dry-run first — it stops at the
   `Proceed?` prompt without a tty, which is fine, the file list above it is what you
   review — then publish from a terminal (it may ask for the Hex password / 2FA):
   ```
   mix hex.publish --dry-run
   mix hex.publish
   ```
   Publish from the tagged tree, nothing else: the package and the `vX.Y.Z` source
   links must agree.

9. **Verify it landed.** `mix hex.info mutare` shows the version; then check
   `https://hexdocs.pm/mutare/changelog.html` renders the entry and that one "source"
   link on a module page (`…/blob/vX.Y.Z/lib/…`) returns 200 — `curl -sI -L -o
   /dev/null -w '%{http_code}'` on each.

10. **Cut the GitHub release** so the changelog's compare/tag links have somewhere to
    land. Body = the changelog entry:
    ```
    awk '/^## \[X\.Y\.Z\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md > /tmp/notes.md
    gh release create vX.Y.Z --title vX.Y.Z --notes-file /tmp/notes.md --verify-tag
    ```

11. **Smoke-test end to end when the release touched the installer, the sandbox, or
    rendering.** Generate a throwaway app and run the real path a user takes:
    ```
    cd /tmp && mix phx.new smoke --app smoke --database sqlite3 --no-install && cd smoke && mix deps.get
    # add {:igniter, "~> 0.8", only: [:dev, :test]} to deps, mix deps.get, then:
    HEX_COOLDOWN=0d mix igniter.install mutare --yes     # own packages ⇒ cooldown bypass is allowed
    grep -c '"mutare_' mix.lock                          # every detected companion must be LOCKED, not just in mix.exs
    mix mutare --max-mutants 40 --workers 2 --verbose    # must reach a score line
    ```
    A Phoenix 1.8 app is the right target: git deps, LiveView, Ecto, Swoosh, Gettext
    all in one.

## The Hex cooldown

The user has agreed to bypass the configured hex cooldown when the dependency is 
his own package, such as `mutare`. Bypass per invocation, not in the config file.
```
HEX_COOLDOWN=0d mix deps.get        # in a companion, to take the fresh core
HEX_COOLDOWN=0d mix hex.publish     # in a companion, if core is still inside the window
```
The resulting `mix.lock` pins the version, and installs from a lockfile don't consult
the cooldown, so it's one bypass per package, not a habit.

## Companion packages release independently

The companion packages (`mutare_plug`, `mutare_phoenix`, `mutare_phoenix_live_view`,
`mutare_ecto`, `mutare_oban`, `mutare_decimal`, `mutare_swoosh`, `mutare_phoenix_swoosh`,
`mutare_gettext`) are **deliberately uncoupled** from the core. Releasing `mutare`
does **not** require touching or re-releasing them:

- The installer adds them with an open requirement (`@companion_requirement
  ">= 0.0.0"` in `lib/mix/tasks/mutare.install.ex`), so `mix deps.get` resolves
  whatever companion version is current and compatible. Nothing to bump here on a
  Mutare release.
- The README's install section names the companions but does not pin them, so it
  needs no edit either. (Its `{:mutare, "~> 0.x", …}` snippet is Mutare's *own*
  version — update that to the new `~>` window on a minor/major, as you would any
  install doc; that's not companion coupling.)

What makes this safe is the **contract**, owned on the companion side: each
companion's own `mix.exs` declares the range of `mutare` it supports, and Mutare
keeps the public behaviours stable within a version line. When a core release breaks
one of those behaviours, flag it in the changelog and the companions update on their
own schedule; when a core *fix* is what a companion needs, the companion raises its requirement and releases itself.

**Releasing a companion** follows the same steps in its own repo (each has the same
`@version`/`source_ref`/changelog/hook layout), with two extras:

- **Order.** `mutare_phoenix` depends on `mutare_plug`, `mutare_phoenix_live_view` on
  `mutare_phoenix`, and `mutare_phoenix_swoosh` on `mutare_swoosh` — a downstream
  package can't resolve (or publish) until its upstream is on Hex. `ecto`, `oban`,
  `decimal`, `gettext` depend only on core.
- **A cooldown bypass** if the core it needs is under the configured cooldown
  limit (see above.)

Each companion's GitHub description is kept equal to its `mix.exs` `description`
(`gh repo edit foxbenjaminfox/<name> --description "…"`).

## Gotchas

- **`mix docs` is the only autolink check** — nothing automated runs it (see the
  `editing-docs` skill). Run it after any moduledoc/changelog edit.
- **Tag the commit you publish.** Never `mix hex.publish` from a tree that differs
  from the tag. If a tag has to move before anything consumed it (nothing on Hex
  yet, nobody fetched it), `git tag -fa` + `git push --force origin vX.Y.Z` is
  acceptable; after a publish it is not.
- **A Mutare release never touches the companions.** They're uncoupled (see above);
  don't re-pin or re-release them as part of shipping the core.
