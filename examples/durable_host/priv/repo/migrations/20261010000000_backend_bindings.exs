defmodule SmolBox.DurableHost.Repo.Migrations.BackendBindings do
  use Ecto.Migration

  def up do
    create table(:smolbox_backend_bindings, primary_key: false) do
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
      add(:kind, :string, null: false)
      add(:generation, :string)
    end

    create(
      constraint(:smolbox_backend_bindings, :backend_binding_shape,
        check:
          "(kind='http' AND generation IS NULL) OR (kind='embedded' AND generation ~ '^[0-9a-f]{32}$')"
      )
    )

    create(
      unique_index(:smolbox_backend_bindings, [:partition, :generation],
        where: "generation IS NOT NULL",
        name: :smolbox_one_native_domain
      )
    )
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM smolbox_backend_bindings WHERE kind='embedded') THEN
        RAISE EXCEPTION 'native backend bindings exist; coordinate readers and preserve assignments before rollback';
      END IF;
    END $$;
    """)

    drop(table(:smolbox_backend_bindings))
  end
end
