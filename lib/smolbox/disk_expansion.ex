defmodule SmolBox.DiskExpansion do
  @moduledoc """
  Durable disk growth intent. Targets are absolute GiB sizes, bounded to 1–64.

  History survives deletion for deduplication. Unknown outcomes retain the entire
  requested reservation; they are never replayed automatically. `:resolved` means
  an operator established quiescence and verified the requested sizes, not that
  the original request's outcome became known.
  """
  alias SmolBox.{Error, Machine, Validation}

  @enforce_keys [:id, :storage_gb, :overlay_gb, :requested_version, :accepted_at_ms, :request]
  defstruct @enforce_keys ++ [state: :pending]

  @type state :: :pending | :dispatching | :unknown | :completed | :resolved | :deleted
  @type targets :: %{
          optional(:storage_gb) => pos_integer(),
          optional(:overlay_gb) => pos_integer()
        }
  @type outcome ::
          :dispatch
          | {:unknown, Error.t()}
          | {:complete, Machine.t()}
          | {:resolve, Machine.t() | :absent}

  @type t :: %__MODULE__{
          id: String.t(),
          storage_gb: pos_integer(),
          overlay_gb: pos_integer(),
          request: targets(),
          requested_version: pos_integer(),
          accepted_at_ms: non_neg_integer(),
          state: state()
        }

  @doc false
  def targets(options) do
    if Validation.keys?(options, [:storage_gb, :overlay_gb]) and options != [] and
         Enum.all?(options, fn {_, n} -> Validation.integer?(n, 1, 64) end),
       do: {:ok, Map.new(options)},
       else: error(:validation)
  end

  @doc false
  def profile(%{disk_sizes: _} = m) do
    sizes = m.disk_sizes || Map.take(m.spec.profile, [:storage_gb, :overlay_gb])
    struct!(m.spec.profile, sizes)
  end

  @doc false
  def expected(%{created_machine: nil}), do: nil

  def expected(%{disk_sizes: _} = m),
    do: struct!(m.created_machine, Map.take(profile(m), [:storage_gb, :overlay_gb]))

  @doc false
  def matches?(m, observed),
    do: expected(m) != nil and Machine.same_incarnation?(expected(m), observed)

  @doc false
  def target_matches?(m, r, observed) do
    wanted = struct!(expected(m), Map.take(r, [:storage_gb, :overlay_gb]))
    Machine.same_incarnation?(wanted, observed)
  end

  @doc false
  def reserved_disk(m) do
    Enum.reduce(m.disk_expansions, m.spec.profile.storage_gb + m.spec.profile.overlay_gb, fn {_,
                                                                                              r},
                                                                                             n ->
      max(n, r.storage_gb + r.overlay_gb)
    end)
  end

  @doc false
  def supported?(m),
    do:
      not m.spec.checkpointable and m.spec.artifact["kind"] != "checkpoint" and
        m.branch == nil and m.branch_children == %{} and m.captures == %{}

  @doc false
  def valid_machine?(m) do
    is_map(m.disk_expansions) and map_size(m.disk_expansions) <= 32 and
      Enum.all?(m.disk_expansions, fn {id, r} -> valid?(r) and id == r.id end) and
      sizes?(m) and active?(m) and (m.disk_expansions == %{} or supported?(m))
  end

  defp sizes?(%{disk_sizes: nil, disk_expansions: history}), do: history == %{}

  defp sizes?(m) do
    initial = Map.take(m.spec.profile, [:storage_gb, :overlay_gb])

    committed =
      Enum.reduce(m.disk_expansions, initial, fn {_, r}, acc ->
        if r.state in [:completed, :resolved],
          do: Map.merge(acc, Map.take(r, [:storage_gb, :overlay_gb]), &larger/3),
          else: acc
      end)

    m.disk_sizes == committed and
      Enum.all?(m.disk_expansions, fn {_, r} ->
        r.storage_gb >= initial.storage_gb and r.overlay_gb >= initial.overlay_gb
      end)
  end

  defp larger(_key, a, b), do: max(a, b)

  defp active?(%{active_expansion: nil} = m),
    do:
      m.operation != :expand_disks and
        Enum.all?(m.disk_expansions, fn {_, r} -> r.state in [:completed, :resolved, :deleted] end)

  defp active?(m) do
    case m.disk_expansions[m.active_expansion] do
      %__MODULE__{state: state} when state in [:pending, :dispatching, :unknown] ->
        exclusive?(m) and
          m.phase == %{pending: :pending, dispatching: :dispatching, unknown: :uncertain}[state] and
          Enum.all?(m.disk_expansions, fn {id, r} ->
            id == m.active_expansion or r.state in [:completed, :resolved, :deleted]
          end)

      _ ->
        false
    end
  end

  defp exclusive?(m),
    do:
      m.operation == :expand_disks and
        Enum.all?(
          [m.active_execution, m.active_export, m.active_capture, m.active_branch],
          &is_nil/1
        )

  defp request_valid?(r),
    do:
      is_map(r.request) and
        match?({:ok, _}, targets(Map.to_list(r.request))) and
        Enum.all?(r.request, fn {k, v} -> Map.fetch!(r, k) == v end)

  defp valid?(%__MODULE__{} = r),
    do:
      Validation.struct_shape?(r, __MODULE__) and Validation.identifier?(r.id) and
        Validation.integer?(r.storage_gb, 1, 64) and Validation.integer?(r.overlay_gb, 1, 64) and
        Validation.integer?(r.requested_version, 1, 9_007_199_254_740_991) and
        Validation.timestamp?(r.accepted_at_ms) and request_valid?(r) and
        r.state in [:pending, :dispatching, :unknown, :completed, :resolved, :deleted]

  defp valid?(_), do: false
  defp error(category), do: {:error, %Error{category: category, operation: :expand_disks}}
end
