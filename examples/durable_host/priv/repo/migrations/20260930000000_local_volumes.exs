defmodule SmolBox.DurableHost.Repo.Migrations.LocalVolumes do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE smolbox_volumes (
      LIKE smolbox_executions INCLUDING DEFAULTS INCLUDING CONSTRAINTS,
      PRIMARY KEY (partition,scope,execution_id),
      FOREIGN KEY (partition) REFERENCES smolbox_partitions ON DELETE CASCADE
    )
    """)

    execute("CREATE INDEX smolbox_volume_usage ON smolbox_volumes (partition,worker_id)")
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM smolbox_volumes) THEN
        RAISE EXCEPTION 'Volume history exists; preserve identities and coordinate every reader/writer before rollback';
      END IF;
    END $$;
    """)

    drop(table(:smolbox_volumes))
  end
end
