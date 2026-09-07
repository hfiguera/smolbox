defmodule SmolBox.DurableHost.Repo.Migrations.CreateSmolboxStore do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE smolbox_partitions (
      partition varchar(128) COLLATE "C" PRIMARY KEY
    )
    """)

    execute("""
    CREATE TABLE smolbox_worker_leases (
      partition varchar(128) COLLATE "C" NOT NULL REFERENCES smolbox_partitions ON DELETE CASCADE,
      worker_id varchar(128) COLLATE "C" NOT NULL,
      owner varchar(128) NOT NULL,
      generation bigint NOT NULL CHECK (generation > 0),
      until_ms bigint NOT NULL CHECK (until_ms >= 0),
      PRIMARY KEY (partition, worker_id)
    )
    """)

    execute("""
    CREATE TABLE smolbox_executions (
      partition varchar(128) COLLATE "C" NOT NULL REFERENCES smolbox_partitions ON DELETE CASCADE,
      scope varchar(128) COLLATE "C" NOT NULL,
      execution_id varchar(128) COLLATE "C" NOT NULL,
      payload bytea NOT NULL,
      fingerprint varchar(64) NOT NULL,
      state varchar(32) NOT NULL,
      version bigint NOT NULL CHECK (version > 0),
      next_due_ms bigint NOT NULL,
      needs_work boolean NOT NULL,
      worker_id varchar(128) COLLATE "C",
      slots integer NOT NULL CHECK (slots >= 0),
      cpus integer NOT NULL CHECK (cpus >= 0),
      memory_mb integer NOT NULL CHECK (memory_mb >= 0),
      disk_gb integer NOT NULL CHECK (disk_gb >= 0),
      PRIMARY KEY (partition, scope, execution_id)
    )
    """)

    execute(
      "CREATE INDEX smolbox_due_work ON smolbox_executions (partition, next_due_ms, scope, execution_id) WHERE needs_work"
    )

    execute("CREATE INDEX smolbox_pending_work ON smolbox_executions (partition, state)")
    execute("CREATE INDEX smolbox_worker_usage ON smolbox_executions (partition, worker_id)")
  end

  def down do
    execute("DROP TABLE smolbox_executions")
    execute("DROP TABLE smolbox_worker_leases")
    execute("DROP TABLE smolbox_partitions")
  end
end
