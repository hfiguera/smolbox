defmodule SmolBox.DurableHost.Repo.Migrations.ManagedPortOwnership do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE smolbox_port_owners (
      worker_id varchar(128) COLLATE "C" NOT NULL,
      host_port integer NOT NULL CHECK (host_port BETWEEN 1 AND 65535),
      partition varchar(128) COLLATE "C" NOT NULL,
      scope varchar(128) COLLATE "C" NOT NULL,
      execution_id varchar(128) COLLATE "C" NOT NULL,
      PRIMARY KEY (worker_id, host_port),
      FOREIGN KEY (partition, scope, execution_id)
        REFERENCES smolbox_managed_machines (partition, scope, execution_id) ON DELETE CASCADE
    )
    """)

    execute(
      "CREATE INDEX smolbox_ports_owner ON smolbox_port_owners (partition,scope,execution_id)"
    )
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM smolbox_port_owners) OR
         EXISTS (SELECT 1 FROM smolbox_managed_machines) OR
         EXISTS (SELECT 1 FROM smolbox_executions WHERE managed_machine_id IS NOT NULL) THEN
        RAISE EXCEPTION 'Cannot downgrade with managed identities; payloads may use schema v5';
      END IF;
    END $$
    """)

    execute("DROP TABLE smolbox_port_owners")
  end
end
