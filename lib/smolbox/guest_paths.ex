defmodule SmolBox.GuestPaths do
  @moduledoc """
  Host-approved lexical guest roots for uploads, downloads and command workdirs.

  Defaults preserve `/workspace`. Roots are absolute and matched by path segment,
  never by raw prefix. An explicit `/` allows every syntactically valid guest path.
  Empty upload/download lists deny that direction; workdirs require at least one
  root. This is API authorization, not symlink containment or a command sandbox.
  Startup workloads and interactive terminals have separate upstream contracts.
  """
  alias SmolBox.Validation

  @fields [:upload_roots, :download_roots, :workdir_roots]
  @derive {Inspect, only: []}
  defstruct upload_roots: ["/workspace"],
            download_roots: ["/workspace"],
            workdir_roots: ["/workspace"]

  @type t :: %__MODULE__{
          upload_roots: [String.t()],
          download_roots: [String.t()],
          workdir_roots: [String.t()]
        }

  @doc """
  Build a canonical policy from `:upload_roots`, `:download_roots`, and
  `:workdir_roots`. Each defaults to `["/workspace"]`, accepts at most 32 absolute
  UTF-8 roots of at most 1024 bytes, and is sorted and deduplicated. Empty file
  direction lists deny access; the working-directory list must be nonempty.
  Paths reject traversal, trailing/repeated separators, percent signs, backslashes
  and NUL. No tilde or environment expansion is performed.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, SmolBox.Error.t()}
  def new(options \\ []) do
    with true <- Validation.keys?(options, @fields),
         true <- Enum.all?(options, fn {_key, roots} -> roots?(roots) end) do
      policy =
        struct!(
          __MODULE__,
          Enum.map(options, fn {key, roots} -> {key, Enum.sort(Enum.uniq(roots))} end)
        )

      if valid?(policy), do: {:ok, policy}, else: invalid()
    else
      _invalid -> invalid()
    end
  end

  @doc false
  def valid?(nil), do: true

  def valid?(%__MODULE__{} = policy) do
    Validation.struct_shape?(policy, __MODULE__) and policy.workdir_roots != [] and
      Enum.all?(@fields, fn key ->
        roots = Map.fetch!(policy, key)
        roots?(roots) and roots == Enum.sort(Enum.uniq(roots))
      end)
  end

  def valid?(_policy), do: false

  @doc "Validate an absolute guest path without granting access to it."
  def absolute?(path) do
    Validation.text?(path, 1024) and String.starts_with?(path, "/") and
      not String.contains?(path, ["%", "\\"]) and
      (path == "/" or Enum.all?(tl(String.split(path, "/")), &(&1 not in ["", ".", ".."])))
  end

  @doc "Check a path against the selected direction, including exact root matches."
  def allowed?(policy, direction, path) when direction in [:upload, :download, :workdir] do
    valid?(policy) and absolute?(path) and
      Enum.any?(roots(policy, direction), &within?(path, &1))
  end

  @doc false
  def subset?(requested, approved) do
    valid?(requested) and valid?(approved) and
      Enum.all?([:upload, :download, :workdir], fn direction ->
        Enum.all?(roots(requested, direction), &allowed?(approved, direction, &1))
      end)
  end

  @doc false
  def roots(nil, direction), do: roots(%__MODULE__{}, direction)
  def roots(policy, :upload), do: policy.upload_roots
  def roots(policy, :download), do: policy.download_roots
  def roots(policy, :workdir), do: policy.workdir_roots

  defp roots?(roots), do: Validation.list?(roots, 32) and Enum.all?(roots, &absolute?/1)
  defp within?(_path, "/"), do: true
  defp within?(path, root), do: path == root or String.starts_with?(path, root <> "/")
  defp invalid, do: {:error, %SmolBox.Error{category: :validation, operation: :guest_path}}
end
