---
name: releasing
description: >-
  Use when cutting an incremental release of Mutare to Hex — bumping the version,
  updating the changelog, tagging, pushing the tag, and running `mix hex.publish`.
  Triggers: "release vX.Y.Z", "cut a release", "publish a new version", "bump the
  version and ship". Covers a follow-on release only; it assumes the package is
  already on Hex (it does not set up the package, license, or hex account).
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
`Mutare.Mutator.MacroHost`, `Mutare.MacroRouting`, `Mutare.UseExpansion`) as the API surface
and bump accordingly. Companion packages are **not** part of this decision — they
version independently (see the last section).

## Steps

Run these on a clean `master` (or the release branch) with nothing uncommitted.

1. **Pre-flight — be green before you touch anything.** The pre-commit hook and CI
   run `mix compile --warnings-as-errors` + `mix check`, but neither runs the slow
   subprocess suite nor validates moduledoc autolinks. Do both yourself:
   ```
   mix test                 # FULL suite incl. :runner + :property (~3 min) — not the fast loop
   mix check                # format-check + credo + dialyzer
   mix docs                 # the ONLY check of @moduledoc/changelog autolinks; must be warning-free
   ```

2. **Bump `@version`** in `mix.exs` (the `@version "X.Y.Z"` line). That is the only
   code change a **patch** release needs — `source_ref` follows automatically.

3. **Update `CHANGELOG.md`** (Keep a Changelog format):
   - Rename the `## [Unreleased]` heading to `## [X.Y.Z] - YYYY-MM-DD` (today's date).
   - Add a fresh empty `## [Unreleased]` section above it.
   - Fill the entry under `### Added` / `### Changed` / `### Fixed` / `### Removed`
     / `### Deprecated` (omit empty groups). Write for *users* — what changed in
     behaviour/config/CLI, not the commit log. A breaking change leads the entry.
   - Update the link refs at the **bottom** of the file: point `[Unreleased]` at
     `compare/vX.Y.Z...HEAD`, and add a `[X.Y.Z]: …/releases/tag/vX.Y.Z` line.

4. **Verify the package contents** before committing — confirm `CHANGELOG.md`,
   `README.md`, `LICENSE`, and `lib/` are present and the `examples/` demos are
   **not**:
   ```
   mix hex.build         # prints the file list and the new version
   ```

5. **Commit.** `git commit -am "Release vX.Y.Z"` (end the message with the
   `Co-Authored-By:` trailer per repo convention). The pre-commit hook re-runs
   compile + check.

6. **Tag — annotated, name must equal `v#{@version}` exactly:**
   ```
   git tag -a vX.Y.Z -m "vX.Y.Z"
   ```
   A tag that doesn't match `@version` breaks every hexdocs "source" link and the
   changelog's release link.

7. **Push the commit and the tag** to `origin` (the GitHub repo behind
   `source_url`, CI, and the changelog's release/compare links). The tag **must**
   be pushed or every hexdocs "source" link and the release link 404:
   ```
   git push origin master && git push origin vX.Y.Z
   ```

8. **Publish to Hex** (publishes the package *and* the docs). Requires a prior
   `mix hex.user auth`. Dry-run first, then publish:
   ```
   mix hex.publish --dry-run
   mix hex.publish
   ```
   Review the file list and version it prints before confirming. A published
   version is effectively immutable — `mix hex.publish --revert X.Y.Z` only works
   within a short window — so the dry-run is the real gate.

9. **Cut the GitHub release** (optional but expected): create a release from the
   `vX.Y.Z` tag with the changelog entry as the body, so the changelog's
   `releases/tag/vX.Y.Z` link resolves.

## Companion packages release independently

The companion packages (`mutare_phoenix`, `mutare_phoenix_live_view`,
`mutare_ecto`, `mutare_oban`, `mutare_gettext`) are **deliberately uncoupled** from
the core. Releasing `mutare` does **not** require touching or re-releasing them:

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
keeps the public mutator/extension behaviours (`Mutare.Mutator`, `Mutare.MacroRouting`,
`Mutare.UseExpansion`, …) stable within a version line. So when a Mutare release breaks
one of those behaviours, flag it in the changelog and the companions update on
their own schedule — the Mutare release is never blocked on them, and a user on an
older companion simply keeps the older, compatible Mutare until the companion
catches up.

## Gotchas

- **`mix docs` is the only autolink check** — nothing automated runs it (see the
  `editing-docs` skill). Run it after any moduledoc/changelog edit.
- **Tag the commit you publish.** Never `mix hex.publish` from a tree that differs
  from the tag — the package and the `vX.Y.Z` source links would disagree.
- **A Mutare release never touches the companions.** They're uncoupled (see above);
  don't re-pin or re-release them as part of shipping the core.
- **The GitHub repo must be public** for hexdocs "source" links and the changelog's
  `releases/...` links to resolve. If `origin`
  (`github.com/foxbenjaminfox/mutare`) is still private, make it public before
  publishing (`gh repo edit foxbenjaminfox/mutare --visibility public`).
