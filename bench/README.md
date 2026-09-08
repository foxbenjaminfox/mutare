# Metamutant compilation

`compile_shapes.exs` generates dependency-free Mix projects and a `sizes.tsv`
table. Generate each revision's fixtures first, then time compilation in fresh
processes with the same Elixir/OTP, scheduler count, and compiler options:

```sh
mix run bench/compile_shapes.exs /tmp/mutare-shapes
cd /tmp/mutare-shapes/case-100
MIX_ENV=test ERL_COMPILER_OPTIONS='[no_ssa_opt_alias,time]' \
  /usr/bin/time -v mix compile --force --no-verification --profile time
```

The command above assumes no inherited Erlang compiler options. When there are
other options, merge `time` and `no_ssa_opt_alias` into them. `--no-verification`
requires Elixir 1.19 or later. The generated projects explicitly disable
signature inference in `elixirc_options`, so Mix 1.20 also compiles with it off.

The table counts parsed source AST traversal nodes, including literal leaves,
using `Macro.prewalk/3`. It also records UTF-8 source bytes and mutation counts.
Compilation timings exclude scanning and rendering but include the Mix VM boot.
Raw measurements under `bench/results/` are local and ignored by Git.
Keep the compiler profile for separating boot, frontend, and backend work.
Use repeated alternating runs; peak RSS is per process, not the sum of all
compiler workers. Final BEAM size cannot measure work eliminated by late passes.

The fixtures vary tupled-case clauses, guard size, arithmetic depth, and focused
selection. Arithmetic covers literal RHS chains with Arithmetic alone and with the
full default set, plus variable RHS chains with the default set. Focused variants
have the same 100-function source and select all, 10, or one mutant. To measure retained-sandbox tradeoffs, copy successive
variants into the *same* generated project and compile **without** `--force`:
unselected branches now disappear, so a changed selection may require recompilation.

For Elixir 1.20's separate module-definition experiment, add
`module_definition: :interpreted` beside `infer_signatures: false` in a generated
project. Restore `:compiled` to return to the ordinary mode. This setting changes
module-definition execution during compilation, not the resulting application's
execution model. It is intentionally not enabled by Mutare.

**Measurements live in [NOTES.md](../NOTES.md), not here.** A table checked in beside
the generator has to be regenerated on every change that moves a byte, and the copy that
rots is the one nobody re-runs. NOTES records what a given experiment measured, dated,
alongside the decision it informed; this file only says how to reproduce one.
