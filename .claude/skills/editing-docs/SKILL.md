---
name: editing-docs
description: >-
  Use when writing or revising this repo's documentation — CLAUDE.md / AGENTS.md,
  a module `@moduledoc`, NOTES.md, README.md, or PHILOSOPHY.md. Mutare keeps five
  documentation layers with a strict division of labor; put each fact in the right
  layer and don't duplicate across them (that's how CLAUDE.md bloated to 17k words).
  Load before adding architecture/rationale prose or when a doc feels too long.
---

# Editing Mutare's docs

Five layers, each with one audience and one job. **Pick the layer by audience and
longevity; never copy the same fact into two.** Duplication is the failure mode —
it drifts, and the lower-value copy is the one that rots.

| Layer | Audience | Owns | Does NOT hold |
| --- | --- | --- | --- |
| `CLAUDE.md` (= `AGENTS.md` symlink) | agents working in the repo | a **navigational map**: commands, one line of role+contract per module, cross-cutting gotchas that span modules, an extension table | per-module mechanics, swap tables, NOTES-summary paragraphs |
| module `@moduledoc` | **published, user-facing** (hexdocs) library users | how that one module works; a family's swap table / exclusions / rationale | cross-module gotchas; the *why-not* history |
| `NOTES.md` | implementers | the **why**: rationale, deferred work, sharp edges, dead ends. Cross-referenced as `NOTES "title"` | how-it-works mechanics (those go in the moduledoc) |
| `README.md` | new users | project overview, install, getting started | internals |
| `PHILOSOPHY.md` | contributors | how the project *thinks* (the design bets) | concrete mechanics |

## Rules

- **CLAUDE.md is a map, not a manual.** If you're explaining *how a single module
  works* there, stop — that's a moduledoc. CLAUDE.md should *point* (`see X's
  moduledoc`, `NOTES "title"`), not inline. Keep it short.
- **Mechanics → moduledoc. Rationale/history → NOTES. Cross-module gotchas → CLAUDE.md.**
  A rule that no *single* moduledoc can hold (e.g. an ownership split between two
  mutator families) is summarized in CLAUDE.md "things that bite", but the canonical
  statement lives in the **owning** module's moduledoc.
- **Verify every pointer.** Before writing "see X's moduledoc" or `NOTES "title"`,
  confirm the target actually carries it. The 17k-word version had pointers to content
  that wasn't where it claimed.
- **Moduledocs are published** (hexdocs) — keep them user-facing, not internal-narrative.
  Internal modules are kept `@moduledoc false`; a visible doc may still *reference* one in
  prose, but its prefix must be listed in the ExDoc autolink skip-list in `mix.exs` (see the
  comment at the top) or `mix docs` warns "references X but it is hidden".
- **Editing CLAUDE.md edits AGENTS.md too** (symlink) — never touch them separately.
- **Know the enforcement gap.** The pre-commit hook and CI run
  `mix compile --warnings-as-errors` + `mix check` (= format-check + credo + dialyzer). None of
  those — nor the compiler — validate `@moduledoc` autolinks; the compiler stores docstrings
  opaquely. Broken or hidden-module autolinks surface **only** under `mix docs` (ExDoc), which
  nothing automated runs. So after touching moduledoc cross-references, run `mix docs` yourself.

## Smell tests

- A CLAUDE.md section restating a module's internals → move it to the moduledoc, leave a one-liner.
- A paragraph that ends `(see NOTES "X")` and *also* explains the whole rationale → the NOTES entry
  is the source; CLAUDE.md/moduledoc should give the conclusion, not re-derive it.
- A moduledoc reading like a logbook ("we tried Y, it broke, so Z") → that history belongs in NOTES;
  the moduledoc states what *is*.
