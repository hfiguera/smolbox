defmodule SmolBox.Embedded.NativeBranchRelease do
  @moduledoc false
  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchCompletion,
    BranchReleaseTransition,
    BranchRequest,
    Shape
  }

  alias SmolBox.Validation

  @enforce_keys [:version, :source, :child, :source_pid, :child_pid, :request]
  @derive {Inspect, only: [:version]}
  defstruct @enforce_keys ++ [transition: nil]

  def new(parent, child, version, env \\ []) do
    source = parent.observed_machine.backend_identity
    owned = child.observed_machine.backend_identity
    id = "release-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    %__MODULE__{
      version: version,
      source: source.receipt,
      child: owned.receipt,
      source_pid: source.pid_identity,
      child_pid: owned.pid_identity,
      request:
        request(id, env, [
          "smolbox-explicit-native-branch-release-v1",
          child.fingerprint,
          version,
          id,
          BranchCanonical.ordered(source.receipt, :receipt),
          BranchCanonical.ordered(owned.receipt, :receipt),
          source.pid_identity,
          owned.pid_identity
        ])
    }
  end

  defp request(id, [], identity),
    do: %{"operation_id" => id, "request_sha256" => BranchCanonical.digest(identity)}

  defp request(id, env, identity) do
    env = Enum.map(env, &Tuple.to_list/1)
    Map.put(request(id, [], identity ++ [env]), "env", env)
  end

  def valid?(%__MODULE__{} = release, %{completion: %BranchCompletion{held: true}} = authority) do
    Validation.struct_shape?(release, __MODULE__) and
      Validation.integer?(release.version, 1, 9_007_199_254_740_991) and
      identity?(release, authority) and processes?(release, authority) and
      BranchRequest.release?(release.request) and
      release.request["operation_id"] != authority.request["child"]["operation_id"] and
      (release.transition == nil or bound?(release.transition, release, authority))
  end

  def valid?(_, _), do: false

  defp identity?(release, authority),
    do:
      Shape.receipt?(release.source, 2) and release.child == authority.completion.child and
        BranchCanonical.origin(release.source) ==
          BranchCanonical.origin(authority.request["source"])

  defp processes?(release, authority),
    do:
      pid?(release.source_pid) and pid?(release.child_pid) and
        hd(release.source_pid) != hd(release.child_pid) and
        release.source_pid ==
          authority.completion.publication["change"]["child_origin"]["intent"]["source_pid"]

  def bound?(%BranchReleaseTransition{} = proof, %__MODULE__{} = release, authority),
    do:
      BranchReleaseTransition.valid?(proof) and proof.previous == release.child and
        proof.change["mode"] == "explicit" and proof.change["request"] == release.request and
        proof.change["binding"] == authority.completion.publication["change"]["child_origin"] and
        proof.change["identity_sha256"] == authority.completion.identity_sha256

  def bound?(_, _, _), do: false

  def preserved?(nil, _), do: true

  def preserved?(%__MODULE__{} = old, %__MODULE__{} = next),
    do:
      %{old | transition: nil} == %{next | transition: nil} and
        (old.transition == nil or old.transition == next.transition)

  def preserved?(_, _), do: false

  defp pid?([pid, birth]),
    do:
      Validation.integer?(pid, 1, 2_147_483_647) and
        Validation.integer?(birth, 1, 18_446_744_073_709_551_615)

  defp pid?(_), do: false
end
