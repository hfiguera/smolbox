defmodule SmolBox.DurableHost.Repo.Migrations.IndexMachineAssignments do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE smolbox_machine_identities (
      partition varchar(128) COLLATE "C" NOT NULL,
      worker_id varchar(128) COLLATE "C" NOT NULL,
      machine_name varchar(31) COLLATE "C" NOT NULL,
      scope varchar(128) COLLATE "C" NOT NULL,
      execution_id varchar(128) COLLATE "C" NOT NULL,
      PRIMARY KEY (partition, worker_id, machine_name),
      UNIQUE (partition, scope, execution_id),
      FOREIGN KEY (partition, scope, execution_id)
        REFERENCES smolbox_executions (partition, scope, execution_id) ON DELETE CASCADE
    )
    """)
  end

  def down, do: execute("DROP TABLE smolbox_machine_identities")
end
