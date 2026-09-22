# Managed persistent machines

Implementation decisions for the first release:

- A `ManagedMachine` owns the worker assignment, reservation, creation evidence,
  lifecycle intent, and one active execution reference. `Machine` remains an
  upstream observation. `ManagedMachineSpec` holds immutable creation intent.
- Commands use the existing execution records and result/file pipeline, with an
  explicit managed-machine reference. Their cleanup releases the command slot,
  never the machine or its resource reservation.
- New store operations are optional for existing adapters. Both bundled adapters
  implement atomic machine/command changes and shared worker capacity accounting.
- Machine operations require the expected record version. Retrying the most recent
  identical request returns its record; superseded requests fail instead of
  reversing a newer intent. Lifecycle dispatch is persisted before HTTP and never
  automatically replayed after uncertainty.
- Full resources stay reserved while stopped. Machines are worker-local and
  retained until explicit deletion; missing machines are never recreated.
- Commands require a running, owned, idle machine. Staging, execution, collection,
  and cancellation hold its command slot. Uncertain commands or interrupted file
  operations block reuse; neither cancellation nor restart deletes the VM.
- Recovery observes durable intent and the worker. An ambiguous mutation requires
  operator quiescence before reuse, because store claims cannot fence HTTP already
  sent upstream. Resolution must verify the owned stopped machine and preserve
  unknown outcomes. Unverified creation cannot be adopted from inventory.
- Disposable records keep their existing encoding. Managed records use a new
  envelope. Upgrade every controller sharing workers/store before enabling the
  feature, including controllers which would otherwise ignore new reservations.
