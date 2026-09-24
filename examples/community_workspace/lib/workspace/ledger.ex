defmodule Workspace.Ledger do
  @moduledoc "Durable browser request identities; SmolBox remains the sole execution authority."
  alias Ecto.Adapters.SQL
  alias Workspace.Repo

  def home(c) do
    case query("SELECT machine_id,label FROM workspace_homes WHERE partition=$1", [
           c.store.partition
         ]).rows do
      [[id, label]] -> %{id: id, label: label}
      [] -> nil
    end
  end

  def put_home(c, id, label) do
    query(
      "INSERT INTO workspace_homes (partition,machine_id,label,inserted_at,updated_at) VALUES ($1,$2,$3,now(),now()) ON CONFLICT(partition) DO NOTHING",
      [c.store.partition, id, label]
    )

    case home(c) do
      %{id: ^id} -> :ok
      _ -> {:error, :identity_conflict}
    end
  end

  def reserve(c, id, machine, kind, payload) do
    bytes = Jason.encode!(payload)

    digest =
      :crypto.mac(:hmac, :sha256, c.settings["encryption"], bytes) |> Base.encode16(case: :lower)

    encrypted = encrypt(c, id, bytes)

    Repo.transact(fn ->
      inserted =
        query(
          "INSERT INTO workspace_actions (partition,id,machine_id,kind,payload,fingerprint,state,inserted_at,updated_at) VALUES ($1,$2,$3,$4,$5,$6,'prepared',now(),now()) ON CONFLICT DO NOTHING",
          [c.store.partition, id, machine, kind, encrypted, digest]
        ).num_rows == 1

      case query(
             "SELECT fingerprint,machine_id,kind,state FROM workspace_actions WHERE partition=$1 AND id=$2",
             [c.store.partition, id]
           ).rows do
        [[^digest, ^machine, ^kind, state]] ->
          {:ok, if(inserted, do: :inserted, else: {:existing, state})}

        _ ->
          {:error, :identity_conflict}
      end
    end)
  end

  def mark(c, id, state, error \\ nil) do
    query(
      "UPDATE workspace_actions SET state=$3,error=$4,updated_at=now() WHERE partition=$1 AND id=$2",
      [c.store.partition, id, state, error]
    )

    :ok
  end

  def actions(c, machine) do
    query(
      "SELECT id,kind,payload,state,error,inserted_at FROM workspace_actions WHERE partition=$1 AND machine_id=$2 ORDER BY inserted_at DESC,id DESC LIMIT 50",
      [c.store.partition, machine]
    ).rows
    |> Enum.map(fn [id, kind, payload, state, error, at] ->
      %{
        id: id,
        kind: kind,
        payload: decrypt(c, id, payload),
        state: state,
        error: error,
        inserted_at: at
      }
    end)
  end

  def action(c, id) do
    case query(
           "SELECT machine_id,kind,payload,state FROM workspace_actions WHERE partition=$1 AND id=$2",
           [c.store.partition, id]
         ).rows do
      [[machine, kind, payload, state]] ->
        {:ok,
         %{
           id: id,
           machine_id: machine,
           kind: kind,
           payload: decrypt(c, id, payload),
           state: state
         }}

      [] ->
        {:error, :not_found}
    end
  end

  def transaction(fun), do: Repo.transact(fun)

  defp query(sql, params),
    do: SQL.query!(Repo, sql, params, log: false, timeout: 5000)

  defp aad(c, id), do: "smolbox-workspace-ui-v1:" <> c.store.partition <> ":" <> id

  defp encrypt(c, id, bytes) do
    iv = :crypto.strong_rand_bytes(12)

    {cipher, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        c.settings["encryption"],
        iv,
        bytes,
        aad(c, id),
        true
      )

    <<1, iv::binary, tag::binary, cipher::binary>>
  end

  defp decrypt(c, id, <<1, iv::binary-size(12), tag::binary-size(16), cipher::binary>>) do
    :crypto.crypto_one_time_aead(
      :aes_256_gcm,
      c.settings["encryption"],
      iv,
      cipher,
      aad(c, id),
      tag,
      false
    )
    |> Jason.decode!()
  end
end
