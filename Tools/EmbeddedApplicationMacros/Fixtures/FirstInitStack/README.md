# First-init stack fixtures

`first_init_stack.py --self-test` executes synthetic control-flow and input
binding fixtures. Cases cover balanced nested frames, compressed stack changes,
branch depths, external branch targets, missing fallthrough, instruction gaps
and duplicate PCs, system traps, unknown instructions, dynamic stack writes,
callback register propagation, all RISC-V link-register aliases, large outlined
callees with unsupported return conventions, recursion, unresolved indirect
calls, symbol aliases, mismatched symbol ranges and instruction bytes, and
forged or stale ROM claims. Adversarial cases also cover a branch that skips an
`lui` callback definition, a branch that skips the trace-begin call, `c.jal`
clobbering, conditional-return paths with direct and indirect zero-link tail
transfers, and callback rejection after `jal zero`/`jal x0`, zero-link
`jalr`, `j`, and `c.j`.

The self-test invokes the real CLI with seeded old reports and malformed
config, callback, and ROM JSON. It checks for a nonzero exit without a
traceback and confirms that no stale report remains. It also checks missing
inputs, an unknown CLI option after `--out`, repeated output options (last
value wins), `--out=path`, rejected abbreviations such as `--ou`, and help
without report mutation. Literal and normalized paths, input/output symlinks,
symlinked parents, and hardlinks are checked to ensure collisions preserve
both the input and any existing output. A bare `--` and a missing output
parent are also exercised. Missing values for every recognized scalar option
and an illegal value for `--self-test` are tested with `--out` both before and
after the parser error. File paths supplied after another malformed option
remain part of collision checks. When the final `--out` has no value, no
destination is selected or cleared, including when an earlier output value
was present.

The binding fixtures also require full ELF function-byte coverage, including
bytes after an early return, and exercise smaller-first and reversed symbol
alias listings. A truncated disassembly that omits a callee block is rejected
before its partial graph can yield a numeric result. All frame sizes remain
candidate diagnostics because byte equality does not decode or establish the
semantics of the supplied disassembly. Numeric stack bounds remain null,
control-flow order remains unproven, and report schema version 3 never returns
`PASS`.

The two JSON files describe saved real-artifact callback sites. Their
`elfSha256` fields identify the corresponding final images. The analyzer checks
these records as candidate evidence but does not claim that local register
propagation proves machine-code semantics. The records do not authenticate
themselves by digest alone.
