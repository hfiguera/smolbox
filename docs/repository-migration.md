# Standalone repository migration

SmolBox was extracted from Keel on September 7, 2026. The local repository is
`/Users/humberto/Projects/smolbox`; its Mix project and Git root are the same
directory. Keel remains a separate repository at `/Users/humberto/Projects/keel`.
Neither a Keel checkout nor a Git submodule is required to develop this library.

## History and source preservation

The extraction used `git subtree split --prefix=packages/smolbox` from Keel commit
`c7db2be974534f6c83ff35da1f8fa58750c0eef9`, without rewriting Keel history.
The extracted tip is `1d3557553f5358b48cb6736fcf401148a2bb38ff`, and its root tree
exactly matches Keel's original package tree:
`dbd6be494d5d6be6c481d8ccefa1513d418fd36f`.

All 30 package commits retain their authors, committers, timestamps, messages and
package trees. Promoting the package to the repository root changes commit IDs;
[keel-history-map.tsv](keel-history-map.tsv) maps every original package commit to
its extracted counterpart. Keel-only commits remain in Keel's history.

Historical JSON evidence is preserved byte for byte. Its source paths and commit
references describe the original Keel runs, not a rerun after migration. For an
old evidence reference, look up its Keel commit prefix in the map and remove the
`packages/smolbox/` prefix when inspecting the extracted tree. Some records refer
to Keel-only commits; those must be inspected in the original Keel history.

The two CI workflows and the SSE fixture's binary Git attribute originally lived
at Keel's root. Their current contents were imported in the migration commit;
their earlier history remains in Keel. Workflow working directories, caches,
lockfile hashes, examples and required-check invocation now use this repository's
root. The CI classifier recognizes only root README/CHANGELOG and Markdown in
`docs/` as documentation-only; old monorepo and Keel idea paths require runtime
validation if introduced here.

The complete local package directory was copied and verified against a 12,321-entry
manifest before validation, including ignored files, symlinks, permissions and the
nested upstream Git checkout. `external-references/` is ignored by this repository
and remains outside formatting, quality analysis and package contents. Copied
build caches were backed up; validation rebuilds the project at its new path.
The preserved Dialyzer PLTs may be reused after dependency checks.

## Validation

The standalone checks below passed on macOS ARM64 with Elixir 1.20.4 / OTP 28.5
before removing Keel's tracked source. Commands run from this repository's root
unless an example directory is specified.

| Check | Result |
|---|---|
| `mix ci` | Passed formatting, unused-lockfile check, compilation with warnings as errors, all 156 deterministic cases (6 properties and 150 ordinary tests), Credo/ExSlop, ExDNA, Credence and Dialyzer |
| `mix smolbox.ci.verify_checks` | Both bad and clean canaries behaved as expected for the compiler, all five requested analyzers, and coverage |
| `python3 -m unittest discover -s scripts/ci -p 'test_*.py' -v` | All 16 CI helper regressions passed, including the adapted root-path classifier and strict aggregate |
| Actionlint 1.7.12, both workflows | Passed; working directories, cache hash inputs and invoked script paths also resolve within this repository |
| `mix docs --warnings-as-errors` | Passed from a fresh dev build |
| `mix compile --warnings-as-errors` in `examples/minimal_host` | Passed from a fresh build |
| `MIX_ENV=test mix compile --warnings-as-errors` in `examples/durable_host` | Passed, including its relative test-support paths |
| `scripts/ci/package_consumer.py` under the canonical toolchain | Built the actual 80-file Hex archive and passed a fresh production consumer, warning-as-error compilation, client/supervisor smoke checks and runtime-only dependency isolation |
| `git fsck --full --no-dangling`, `git diff --check` | Passed; no Git object alternates or parent-repository dependency |

Credo executed 100 checks on 117 files, ExDNA analyzed 71 files with zero clones,
Credence checked 122 files, and Dialyzer reported zero errors. The root `lib/`,
`mix.exs`, lockfiles, example source and historical evidence JSON remain byte for
byte identical to the extracted package. The migrated binary attribute preserves
the captured SSE fixture exactly.

The migration archive has SHA-256
`4b733d8fd7f29e8079860d784acd81cd82e8f471b8ec8e8d34db81611409e39d`.
Its consumer report has SHA-256
`629e52dcdcd2b866612175b42f319f25140282aa48f18a58104f3ae6dfdf6793`.
Local logs, report, archive, full source manifest and the pre-migration Git bundle
were retained in the private migration backup directory:
`/var/folders/9p/b5vht97d40x618n_gy_0yrpw0000gn/T/smolbox-repository-migration-l864uaox`.
The original package directory is also retained there when removed from Keel;
the working upstream reference now lives in this standalone checkout.

The 14 real-runtime cases are intentionally excluded from this deterministic
run. Live Linux/macOS suites, durable database tests, the full toolchain matrix,
full-project coverage and hosted GitHub Actions were not rerun for the migration.
The example compile and consumer smoke checks do not substitute for those tests.
The original runtime evidence retains its original scope; this migration does
not qualify a new release or provision protected runners.

## Local use and remote setup

Keel has no root Mix project yet, so no dependency declaration is added there.
When a consumer's Mix project lives at the neighboring repository root, local
development can use:

```elixir
{:smolbox, path: "../smolbox"}
```

Adjust the path relative to the consuming Mix project. Other contributors need
their own checkout or, once available, a reviewed Git/Hex dependency. The local
standalone repository has no remote; no hosting account or source URL has been
invented, and nothing has been pushed or published. Source metadata and protected
CI environments/runners must be configured for the actual destination repository.
This migration does not complete the outstanding release qualification described
in [implementation-plan.md](implementation-plan.md).
