# Embedded Port release review

The distribution review is complete as a gap assessment. **Publication remains
blocked.** No Developer ID signature, notarization, publisher attestation or license
compliance approval is claimed by the ordinary development proofs.

## Integrity and provenance

The helper uses SDK 1.22.0 revision
`9f446ae00219148ca4a703914f44a8e2fab11655`. Bootstrap verifies the source archive,
complete unmodified content/mode inventory and lock inputs recorded in
`vendor/source.json`. It rejects patch lists and native Cargo source overrides.
The earlier clean engine-0.1.0 development packages have their own ordinary
Linux/macOS platform/consumer evidence. Those results remain attached to their
exact identities. Expanded engine-0.2.0 packages need their own source, policy,
asset and ordinary feature acceptance. At source 766b3a11, the isolated macOS
build passes eight compile/package/signature/source-integrity stages on manifest
947ad46c/helper 407bcee7; this is build evidence, with native qualification still
pending. See the [current completion audit](../docs/design/embedded-port-http-parity-completion-audit.md)
and [scoped build record](../docs/evidence/embedded-port-http-parity-macos-build-766b3a11.json).
The matching [Linux build](../docs/evidence/embedded-port-http-parity-linux-build-766b3a11.json)
passes 12 stages, 1,322 workspace tests (24 ignored) and 13 witness models on
manifest 0faf74dc/helper 2655ed9b. Neither build starts a native owner or VM.
Old patched package identities and proof results remain historical. A digest establishes
integrity of approved bytes; it is not publisher authentication or a reproducible
build attestation.

The [corrected macOS ordinary package](../docs/evidence/embedded-port-http-parity-macos-relay-ordinary-7b05cf60.json) at source 7b05cf60 uses manifest 0735ee82/helper d1f8a583. Exact current/minimum no-Rust public consumers now pass offline local-container lifecycle/files/managed terminals, draining, normal stopped-machine Runtime replacement with Memory alive and owned cleanup. All 809 assets verify after use; original build inputs retain their bytes and modes. This scoped development acceptance does not supply full HTTP parity, changed-helper upgrade, crash qualification, publisher authentication or distribution approval. Earlier failed attempts keep their own preserved evidence.

The [f1f250d3 source/image package](../docs/evidence/embedded-port-http-parity-macos-public-sources-f1f250d3.json)
adds four scoped macOS current/minimum no-Rust public consumers on manifest
1a8e644f/helper fe85a410. Configured OCI/images and offline bare registry
cold/warm workflows pass binary files, normal Runtime replacement and owned
cleanup. All 656 installed files and seven proof inputs per consumer verify;
both private archives and semantic v19 readers verify. SDK tables and native
process inventories end empty, the account lock is free and all 809 package
assets unchanged. This is development feature acceptance. Publisher signing,
notarization, firmware/source correspondence and license delivery remain open;
no broader parity, helper-upgrade or crash qualification is inferred.

The updated builder includes `SMOLBOX-LICENSE`, `SMOLVM-LICENSE`,
`SMOLVM-LICENSES.md` and `NATIVE-SOURCE.json` in the hashed asset inventory. Earlier
packages carried two SDK license files outside that inventory. These packages have
distinct manifest and asset digests; evidence does not transfer between them.
`NATIVE-SOURCE.json` identifies the pinned SDK archive/inventory. It is not a
complete SmolBox source-commit, dependency or firmware attestation. Separate
source inventories and build records must bind the helper's actual engine and
bridge source to its executable digest.

Earlier clean engine-0.1.0 packages use manifest schema 2. They require the exact compiled policy in
both the manifest and hashed `SMOLBOX-POLICY.json`, plus exact compiled source
metadata in hashed `NATIVE-SOURCE.json`. Policy version 1 records exclusive
cooperating domain ownership, observation schema 1, and versions of SmolBox's
transfer supervisor, boot guard and asset preparation; Rustler remains disabled.
Configuration binds these fields through its approved manifest SHA-256. Public
Policy now also binds Port protocol minor 4 and native cancellation grace. The
epoch-bound unavailable notice preserves ownership and capacity while stopping
admission. Approved legacy schema 1 / Hello 1.3 packages retain their original
limits and cannot satisfy a clean manifest. Old manifest approvals cannot be
substituted for changed source/build/asset/policy identities. This integrity check
does not authenticate a publisher or establish firmware correspondence.

Expanded engine-0.2.0 packages use manifest schema 3, policy schema 2,
configuration schema 2 and Port protocol 2.0. SDK version/revision remain
independent of those SmolBox versions. The compiled platform policy, SDK feature
versions, limits, hashed policy/source metadata and approved package identity
must agree. Optional descriptor presence is not ordinary qualification, and
the [current admission audit](../docs/evidence/embedded-port-http-parity-current-admission-audit.json)
records required features still absent from the Linux/macOS approval policies.
Legacy 1.3/1.4 readers and older receipts keep their own versions; a changed
package cannot adopt their operational authority by relabelling it.

macOS builds must give the unmodified SDK a private working library copy through
`LIBKRUN_BUNDLE`: upstream build logic rewrites/re-signs that directory. The
[recorded input-mode incident](../docs/evidence/embedded-port-http-parity-macos-build-input-mode.json)
and subsequent isolated rebuild distinguish successful package signing from input
preservation. Neither action opens the quarantined SDK domain or grants native
feature acceptance.

macOS development builds are ad-hoc signed with hypervisor entitlements. Linux
packages are digest pinned. `--signing-identity` supports an explicit macOS identity
with timestamped library signatures and hardened helper signing, but this path has
not been qualified with a distribution identity. Release work must produce and
verify the actual signed bytes, notarize/staple as applicable, authenticate the
manifest and rerun consumers against those exact bytes.

## License and source delivery gaps

SmolBox supplies its MIT license; the verified SDK supplies Apache-2.0 texts and
its upstream component summary. The inspected [libkrun license](https://github.com/libkrun/libkrun/blob/3285db7404144ed61faf0848bb424c0f82743f41/LICENSE)
is Apache-2.0. Upstream [libkrunfw licensing](https://github.com/libkrun/libkrunfw#license)
distinguishes LGPL library code and GPL kernel/patches and describes corresponding
source delivery with distributed binaries.

The SDK's generic component versions do not establish correspondence with every
actual packaged library and firmware binary. Research checkout revisions are not
binary attestations. Before distribution, inventory all linked Rust dependencies,
copyrights and notices; establish the exact libkrun, firmware and kernel versions,
configuration, patches and build recipes; provide applicable corresponding sources
and satisfy delivery/relinking obligations. Audit the guest agent and root filesystem
packages as well. Copying license texts alone does not close this gate.

## Development admission and distribution gate

Public Runtime admission accepts explicitly configured development Port targets.
Historical patched-package lifecycle campaigns cover ordinary startup, execution,
file collection, draining, normal Runtime restart with a surviving store and owned
deletion. Selected Linux boot/helper-loss and macOS durable interruption cases also
passed for those historical packages. These results do not qualify new clean
packages. Their identities and scope remain separate from clean qualification.
The new [clean-package evidence](../docs/evidence/embedded-port-unmodified-sdk-ordinary.json)
records passing macOS ordinary lifecycle, current/minimum public consumers,
PostgreSQL-backed Runtime replacement and compatible clean helper replacement.
Both platforms passed current/minimum public consumers, PostgreSQL-backed normal
Runtime replacement, compatible clean helper replacement and bare-VM snapshot
import/retention. The PostgreSQL lifecycle uses
ordinary Runtime shutdown with its store alive, without injected persistence loss.
The remaining crash/CLI-race campaign is deferred at the user's request;
complete crash qualification is not claimed. The latest
[progress record](../docs/design/embedded-port-progress.md) preserves tested scope,
an unresolved Linux verification failure and the stop request.

Distribution approval remains separate: complete independent SDK interference
races when separately authorized, exact native source/license delivery, publisher
provenance and distribution signing, then rerun consumers against the resulting
bytes. Ordinary HTTP-parity completion also requires all current operation,
source, platform, durable-store and upgrade gates in the completion audit;
historical offline qualification cannot close them. No native package is
published by this change. Local manifest approval is not publisher authentication.
