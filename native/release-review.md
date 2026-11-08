# Embedded Port release review

The distribution review is complete as a gap assessment. **Publication remains
blocked.** No Developer ID signature, notarization, publisher attestation or license
compliance approval is claimed by the ordinary development proofs.

## Integrity and provenance

The helper uses SDK 1.22.0 revision
`9f446ae00219148ca4a703914f44a8e2fab11655`. Bootstrap verifies the source archive,
complete unmodified content/mode inventory and lock inputs recorded in
`vendor/source.json`. It rejects patch lists and native Cargo source overrides.
The clean development packages have been rebuilt with exact source/policy bytes
and complete asset inventories verified. Linux/macOS ordinary platform/consumer
qualification passed, and the macOS signature/entitlement were verified. Old patched
package identities and proof results remain historical. A digest establishes
integrity of approved bytes; it is not publisher authentication or a reproducible
build attestation.

The updated builder includes `SMOLBOX-LICENSE`, `SMOLVM-LICENSE`,
`SMOLVM-LICENSES.md` and `NATIVE-SOURCE.json` in the hashed asset inventory. Earlier
packages carried two SDK license files outside that inventory. These packages have
distinct manifest and asset digests; evidence does not transfer between them.
`NATIVE-SOURCE.json` describes helper/SDK inputs, not complete firmware provenance.

Clean packages use manifest schema 2. They require the exact compiled policy in
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
races, exact native source/license delivery, publisher provenance and distribution
signing, then rerun consumers against the resulting bytes. No native package is
published by this change. Local manifest approval is not publisher authentication.
