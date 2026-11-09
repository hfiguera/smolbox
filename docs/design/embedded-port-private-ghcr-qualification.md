# Private GHCR qualification

Close the production TLS evidence gap for `prepare_artifact` and the registry
credentials specification. Use the approved Embedded Port packages on Linux
x86_64 and macOS ARM64 with Elixir 1.20.4/OTP 29.0.6 and Elixir 1.18.4/OTP
27.3.4.15. Keep smolvm at `9f446ae00219148ca4a703914f44a8e2fab11655`.
Crash and CLI-race validation remain deferred.
[Current coverage](embedded-port-http-parity-coverage.json)

## Fixtures and local setup

- Stage two private GHCR packages under the operator's namespace. The prepared
  package holds a previously qualified container-mode `.smolmachine` for each
  guest architecture.
  The OCI package holds distinct BusyBox boot and pull images for each
  architecture. Each OCI image includes a unique marker so a successful cold
  pull can be tied to the fixture.
- Provide a short-lived classic GitHub PAT with `write:packages` for the
  publisher and a separate classic PAT with `read:packages` for the test
  reader. Grant that reader access to both packages. Authorize SSO for the
  tokens if the namespace requires it. Use the local setup script's hidden
  input prompts to keep the values out of chat and the repository.
  [GitHub Container Registry authentication](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry#authenticating-to-the-container-registry)
- Before uploading, check that the package names are unused or already
  private. Verify private visibility, resolve each uploaded tag to its
  digest with the reader, and compare it with the staged manifest digest.
  Record the prepared layer SHA-256 and OCI configuration digests separately.
  Prove that anonymous requests cannot read the private manifests.

The fixture setup and approved digest ledger live under the ignored
`.local/http-parity/private-ghcr` directory. Qualification runners receive the
digest ledger and a protected account configuration. The publisher credential
is used only for fixture publication. Approved fixture names, hashes and
sanitized outcomes can enter version control.

Run these commands from the repository root to configure the test logins
through the hidden prompts.

```sh
python3 .local/http-parity/private-ghcr/configure.py writer
python3 .local/http-parity/private-ghcr/configure.py reader
```

## Four qualification lanes

Run current and minimum on each platform. Use dedicated test accounts, new
PostgreSQL partitions, verified helper manifests and an installed consumer
without Rust on its path. Require ordinary host and guest trust stores and
certificate and hostname verification. Use the normal network-enabled Linux
provisioning lab. Approve the exact OCI registry and required content hosts in
the guest network policy. When reusing a macOS native domain, keep the approved
package at the absolute path already recorded for that manifest.

1. Before any successful preparation in that scope, exercise
   `Backend.prepare_artifact` with an invalid credential against the approved
   private pack. Verify refusal before a machine is created and check zero
   reservations. Configure the reader in the worker's machines registry
   account settings, then prepare the digest, check the manifest and content
   hashes, and boot the prepared machine offline. Verify a guest marker and
   delete the machine normally.
2. Configure the reader in the images registry account settings. Cold-boot
   the pinned private OCI boot image and read its marker. Pull the second
   private image through `Machines.pull_image`, verify its configuration
   digest and the guest inventory, and repeat the same request to check
   idempotence. Stop and delete the owned machine normally.
3. Read back the exact completed executions and machine tombstones from a
   fresh workerless PostgreSQL reader. Verify zero reservations, empty SDK
   inventory and normal helper and PostgreSQL shutdown. Keep any uncertain
   operation's original records for inspection.

GHCR's username and PAT exercise the account Basic credential path. The
explicit `credential_ref` path sends a bearer identity token to the exact
approved HTTPS realm. Qualify it with a registry and realm that accept that
exchange if GHCR rejects it. Existing fixture-CA evidence covers realm
pinning, rotation and secret-free records. Report the production Basic and
explicit reference results separately before deciding whether the coverage
entry can close.
[SmolBox registry configuration](../images-and-registry-artifacts.md#networking-and-authentication)

## GHCR blob redirect

The private manifests were readable with the reader and refused anonymously.
Authenticated blob requests for the prepared payload and OCI configurations
returned a 307 from `ghcr.io` to `pkg-containers.githubusercontent.com`. The
shared SmolBox engine now permits that exact GHCR host pair for blob
downloads. It allows one HTTPS hop on port 443 with a 307 or 308 response,
issues a fresh GET without registry credentials, and verifies the downloaded
bytes against the pinned descriptor.

The first macOS rerun downloaded and verified the original bare artifact.
The fixture declares 1 GiB each for storage and overlay, while the test profile
requested 4 GiB and 3 GiB. Managed creation returned `unsupported_capability`
with an unknown outcome, and that scope was preserved. The lifecycle reruns use
the previously qualified container packs under separate private tags, with the
original OCI images.

GHCR accepted the classic reader PAT through Basic authentication. Using the
same PAT as a bearer identity credential at its token realm did not grant
access to the private manifest.
The explicit reference case needs a compatible token realm for qualification
under public trust.
[Baseline GHCR evidence](../evidence/embedded-port-http-parity-private-ghcr-e03a29b0.json)

All four lanes passed the private GHCR account Basic workflow. Each recovered
two deleted machine records and three completed executions from PostgreSQL
without a native worker, verified zero reservations and an empty SDK inventory,
and stopped normally.
[GHCR rerun evidence](../evidence/embedded-port-http-parity-private-ghcr-redirect-e03a29b0.json)
