defmodule Workspace.Repo.Migrations.WorkspaceUI do
  use Ecto.Migration

  def up do
    create table(:workspace_homes, primary_key: false) do
      add(:partition, :string, primary_key: true)
      add(:machine_id, :string, null: false)
      add(:label, :string, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create table(:workspace_actions, primary_key: false) do
      add(:partition, :string, primary_key: true)
      add(:id, :string, primary_key: true)
      add(:machine_id, :string, null: false)
      add(:kind, :string, null: false)
      add(:payload, :binary, null: false)
      add(:fingerprint, :string, null: false)
      add(:state, :string, null: false, default: "prepared")
      add(:error, :string)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:workspace_actions, [:partition, :machine_id, :inserted_at]))
  end

  def down do
    raise "Workspace identities must be retained; export and explicitly migrate history before rollback"
  end
end
