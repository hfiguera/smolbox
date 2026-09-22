defmodule SmolBox.DurableHost.Repo.Migrations.ManagedPersistentMachines do
  use Ecto.Migration

  def up do
    execute(
      "ALTER TABLE smolbox_executions ADD COLUMN managed_machine_id varchar(128) COLLATE \"C\""
    )

    execute("""
    CREATE TABLE smolbox_managed_machines (
      LIKE smolbox_executions INCLUDING DEFAULTS INCLUDING CONSTRAINTS,
      machine_name varchar(31) COLLATE "C",
      PRIMARY KEY (partition,scope,execution_id),
      FOREIGN KEY (partition) REFERENCES smolbox_partitions ON DELETE CASCADE,
      UNIQUE (partition,worker_id,machine_name)
    )
    """)

    execute(
      "CREATE INDEX smolbox_machines_due ON smolbox_managed_machines (partition,next_due_ms,scope,execution_id) WHERE needs_work"
    )

    execute(
      "CREATE INDEX smolbox_machines_usage ON smolbox_managed_machines (partition,worker_id)"
    )

    execute(
      "CREATE INDEX smolbox_machine_commands ON smolbox_executions (partition,scope,managed_machine_id) WHERE managed_machine_id IS NOT NULL"
    )
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM smolbox_managed_machines) OR
         EXISTS (SELECT 1 FROM smolbox_executions WHERE managed_machine_id IS NOT NULL) THEN
        RAISE EXCEPTION 'Cannot downgrade while managed machine identities or commands exist';
      END IF;
    END $$
    """)

    execute("DROP TABLE smolbox_managed_machines")
    execute("ALTER TABLE smolbox_executions DROP COLUMN managed_machine_id")
  end
end
