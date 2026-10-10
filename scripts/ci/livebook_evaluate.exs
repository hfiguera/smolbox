# This file runs inside pinned Livebook 0.19.10. Keep its private API calls here,
# outside the dependency-free CI modules and outside the published package.
workspace = System.fetch_env!("SMOLBOX_LIVEBOOK_WORKSPACE")
"0.19.10" = to_string(Application.spec(:livebook, :vsn))
source = File.read!(Path.join(workspace, "notebook.livemd"))
{notebook, imported} = Livebook.LiveMarkdown.Import.notebook_from_livemd(source)

{:ok, session} =
  Livebook.Sessions.create_session(
    notebook: notebook,
    autosave_path: Path.join(workspace, "autosave")
  )

cells = fn notebook ->
  [notebook.setup_section | notebook.sections]
  |> Enum.flat_map(& &1.cells)
  |> Enum.filter(&is_struct(&1, Livebook.Notebook.Cell.Code))
end

ids = Enum.map(cells.(notebook), & &1.id)
deadline = System.monotonic_time(:millisecond) + 420_000

wait = fn again ->
  data = Livebook.Session.get_data(session.pid)
  evaluations = Enum.map(ids, &Map.fetch!(data.cell_infos, &1).eval)

  cond do
    Enum.any?(evaluations, & &1.errored) ->
      data

    Enum.all?(evaluations, &(&1.validity == :evaluated and &1.status == :ready)) ->
      data

    System.monotonic_time(:millisecond) >= deadline ->
      data

    true ->
      Process.sleep(200)
      again.(again)
  end
end

try do
  Livebook.Session.queue_full_evaluation(session.pid, [])
  data = wait.(wait)

  statuses =
    Enum.map(cells.(data.notebook), fn cell ->
      eval = data.cell_infos[cell.id].eval
      %{id: cell.id, validity: eval.validity, status: eval.status, errored: eval.errored}
    end)

  {export, warnings} =
    Livebook.LiveMarkdown.Export.notebook_to_livemd(data.notebook,
      include_outputs: true,
      include_stamp: false
    )

  true = byte_size(export) <= 2_097_152
  File.write!(Path.join(workspace, "evaluated.livemd"), export)
  probe = List.last(cells.(data.notebook))

  markers =
    probe.outputs
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(fn
      {_, %{type: :terminal_text, text: text}} -> text
      _ -> ""
    end)
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "SMOLBOX_LIVEBOOK_RESULT="))

  checks =
    case markers do
      ["SMOLBOX_LIVEBOOK_RESULT=" <> json] -> Jason.decode!(json)
      _ -> %{}
    end

  passed =
    ids != [] and imported.warnings == [] and warnings == [] and
      Enum.all?(
        statuses,
        &(&1.validity == :evaluated and &1.status == :ready and &1.errored == false)
      ) and
      map_size(checks) == 7 and Enum.all?(checks, fn {_, value} -> value === true end)

  report = %{
    status: if(passed, do: "passed", else: "failed"),
    cells: statuses,
    checks: checks,
    livebook_version: to_string(Application.spec(:livebook, :vsn)),
    runtime: to_string(data.runtime.__struct__),
    import_warnings: imported.warnings,
    export_warnings: warnings
  }

  File.write!(Path.join(workspace, "evaluation.json"), Jason.encode!(report))
  report
after
  monitor = Process.monitor(session.pid)
  Livebook.Session.close(session.pid)

  receive do
    {:DOWN, ^monitor, :process, _, _} -> :ok
  after
    5_000 -> raise "Livebook session did not close"
  end
end
