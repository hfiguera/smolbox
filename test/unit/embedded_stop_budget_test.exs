defmodule SmolBox.EmbeddedStopBudgetTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.EmbeddedReply
  alias SmolBox.Embedded.Protocol
  alias SmolBox.Error

  @empty %{stdout: <<>>, stderr: <<>>, file: <<>>}
  for {code, category} <- [{"deadline", :expired}, {"cancelled", :unknown}],
      {dispatch, evidence} <- [
        {"not_dispatched", :not_dispatched},
        {"may_have_dispatched", :dispatch_uncertain}
      ] do
    test "stop #{code} #{dispatch} preserves the existing public error vocabulary and evidence" do
      outcome = %{"result" => "error", "code" => unquote(code), "dispatch" => unquote(dispatch)}
      assert Protocol.valid_outcome?(outcome, 2)

      assert {:error,
              %Error{category: unquote(category), operation: :stop, evidence: unquote(evidence)}} =
               EmbeddedReply.decode(nil, :stop, nil, {:ok, outcome, @empty, nil})
    end
  end
end
