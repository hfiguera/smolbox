# Unmodified native SDK source

`source.json` records the smolvm revision, full Git tree identity, archive SHA-256
and authenticated complete content/executable-mode inventory. It declares zero
patches. The archive was made with `git archive` from clean revision
`bc58c3ef808e70db10c0ffb2b282c5f565ac6afc` at tag `v1.35.1`. All 374
exported files were compared with upstream Git blobs and modes. The full tree is
`a86c733196fb418dfccf272e288c3205e908faff`; this is a selected SDK export,
including source/crates, manifests, build script, toolchain and license documents.
The research checkout under `external-references` is never a build input.

`python3 native/bootstrap.py` verifies the archive and inventory, rejects unsafe
archive paths, patch configuration and native Cargo overrides, and compares every
cached file and executable mode with upstream. The normal workspace uses
`native/target/upstream/smolvm`. `--check` rejects a missing or changed cache
without replacing it. Bootstrap contains no patch application or source rewrite.
Python 3.12+ is required; Git and network access are not needed to materialize the
archive. Cargo may need to fetch its locked registry dependencies.

`--clean` selects the independent API/resolver fixture cache
`native/target/upstream/smolvm-clean`, using the same manifest and inventory.
It is also unmodified source. See the [boundary audit](../clean-sdk-api-boundaries.md)
for verified APIs and remaining qualification. The generated independent fixture
lockfile stays outside version control.

Rust builds consume exact-version path dependencies and locked registry versions.
An SDK upgrade must regenerate the archive and authenticated inventory from the
intended exact commit, review the compatibility schema/paths, update the dependency
pin and lockfile, and rerun applicable ordinary validation. Never rewrite cached
SDK source, introduce a fork or transfer package approvals to changed bytes.

The source remains Apache-2.0; `LICENSE` and `THIRD-PARTY-NOTICES.md` are in the archive.
SmolBox's native crates use the repository MIT license. This archive includes no
libkrun/libkrunfw binaries, firmware, rootfs or disk templates. Their exact
provenance/license audit and corresponding-source delivery remain separate
[distribution requirements](../release-review.md). Existing patched-package
approvals/evidence remain historical.

This is the 1.35.1 development build input. HTTP/checkpoint and public installer
defaults remain 1.34.0 until the new qualification and distribution gates pass.
Previously approved 1.34.0 and 1.22.0 packages and historical proofs retain their
exact identities; this source change never upgrades an existing domain in place.
