defmodule SmolBox.DurableHost.Repo.Migrations.WorkerAdmissionControls do
  use Ecto.Migration

  def up do
    create table(:smolbox_worker_controls, primary_key: false) do
      add(
        :partition,
        references(:smolbox_partitions,
          column: :partition,
          type: :string,
          on_delete: :delete_all
        ),
        primary_key: true
      )

      add(:worker_id, :string, primary_key: true)
      add(:mode, :string, null: false)
      add(:version, :bigint, null: false)
      add(:request_version, :bigint)
      add(:updated_at_ms, :bigint, null: false)
    end

    create(
      constraint(:smolbox_worker_controls, :worker_control_mode,
        check: "mode IN ('active','draining')"
      )
    )

    create(
      constraint(:smolbox_worker_controls, :worker_control_version,
        check:
          "version > 0 AND (request_version IS NULL OR request_version = version - 1) AND updated_at_ms >= 0"
      )
    )
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM smolbox_worker_controls) THEN
        RAISE EXCEPTION 'worker control history exists; preserve it and coordinate all controllers before rollback';
      END IF;
    END $$;
    """)

    drop(table(:smolbox_worker_controls))
  end
end
