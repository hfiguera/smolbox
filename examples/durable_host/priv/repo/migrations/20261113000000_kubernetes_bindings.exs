defmodule SmolBox.DurableHost.Repo.Migrations.KubernetesBindings do
  use Ecto.Migration

  def up do
    alter(table(:smolbox_backend_bindings), do: add(:payload, :binary))
    drop(constraint(:smolbox_backend_bindings, :backend_binding_shape))

    create(
      constraint(:smolbox_backend_bindings, :backend_binding_shape,
        check:
          "(kind='http' AND generation IS NULL AND payload IS NULL) OR " <>
            "(kind='embedded' AND generation ~ '^[0-9a-f]{32}$' AND payload IS NULL) OR " <>
            "(kind='kubernetes' AND generation ~ '^[0-9a-f]{64}$' AND payload IS NOT NULL)"
      )
    )
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM smolbox_backend_bindings WHERE kind='kubernetes') THEN
        RAISE EXCEPTION 'Kubernetes bindings exist; preserve authority before rollback';
      END IF;
    END $$;
    """)

    drop(constraint(:smolbox_backend_bindings, :backend_binding_shape))

    create(
      constraint(:smolbox_backend_bindings, :backend_binding_shape,
        check:
          "(kind='http' AND generation IS NULL) OR (kind='embedded' AND generation ~ '^[0-9a-f]{32}$')"
      )
    )

    alter(table(:smolbox_backend_bindings), do: remove(:payload))
  end
end
