# Sequence fixtures

`reads.fastq` is the small synthetic read fixture used by the scalar and FASTQ examples.

`references.fasta` contains eight manually constructed records for the synthetic
complete guide `ACGTNGG` (four-base protospacer, three-base PAM). It is a software
conformance fixture, not an experimental guide design or a population sample.

With exact PAM filtering, both strands and `max_n_frac = 0.2`, the zero-edit hits
are `forward` and `masked` at `[2,9)` on `+`, and `reverse` at `[2,9)` on `-`.
The one-edit controls include `insertion` at `[2,10)` and `deletion` at `[2,8)` on
`+`. `pam_edit` has a PAM substitution; `ambiguous` has four N bases in the target
match; `no_hit` is a negative control. Soft masking is exercised directly by the
native tests; FASTA wrappers preserve the values exposed by the DuckHTS reader.

The CLI comparator uses the same physical FASTA for both implementations. Sassy
retains full FASTA headers while DuckHTS exposes the first token as `NAME`; this
fixture has unique first tokens, which define the comparison key. Every duplicate
guide and every emitted hit remains in the multiset comparison.
