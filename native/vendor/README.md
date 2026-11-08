# Unmodified native SDK source

`source.json` records the smolvm revision, full Git tree identity, archive SHA-256
and authenticated complete content/executable-mode inventory. It declares zero
patches. The archive was made with `git archive` from clean revision
`9f446ae00219148ca4a703914f44a8e2fab11655` in an independent checkout. All 290
exported files were compared with upstream Git blobs and modes. The full tree is
`81265fb74951f9e35ac3942f7b18545b1de9f2d9`; this is a selected SDK export,
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

The source remains Apache-2.0; `LICENSE` and `Licenses.md` are in the archive.
SmolBox's native crates use the repository MIT license. This archive includes no
libkrun/libkrunfw binaries, firmware, rootfs or disk templates. Their exact
provenance/license audit and corresponding-source delivery remain separate
[distribution requirements](../release-review.md). Existing patched-package
approvals/evidence remain historical. Crash qualification stays deferred.
