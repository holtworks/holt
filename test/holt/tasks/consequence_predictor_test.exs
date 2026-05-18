defmodule Holt.Tasks.ConsequencePredictorTest do
  use ExUnit.Case, async: true

  alias Holt.Tasks.ConsequencePredictor

  test "consequence predictions use canonical action_contract" do
    prediction =
      ConsequencePredictor.predict(%{
        "action_contract" => %{
          "contract_id" => "contract-1",
          "action" => "write",
          "effect_scope" => "workspace_durable",
          "risk_level" => "high",
          "target_domain" => "workspace",
          "target_refs" => %{"path" => "README.md"}
        },
        "action_preflight" => %{"preflight_id" => "preflight-1", "result" => "passed"}
      })

    assert prediction["contract_id"] == "contract-1"
    assert prediction["effect_scope"] == "workspace_durable"
    assert prediction["risk_level"] == "high"
    assert prediction["expected_state_delta"]["target_refs"] == %{"path" => "README.md"}
  end

  test "consequence predictions reject legacy contract argument" do
    assert %{"status" => "rejected", "reason" => "unsupported_argument:contract"} =
             ConsequencePredictor.predict(%{
               "contract" => %{
                 "contract_id" => "legacy-contract",
                 "action" => "read"
               }
             })
  end

  test "consequence predictions reject atom-keyed contracts" do
    assert %{"status" => "rejected", "reason" => "invalid_attrs"} =
             ConsequencePredictor.predict(%{
               action_contract: %{
                 "contract_id" => "contract-1",
                 "action" => "read"
               }
             })

    assert %{"status" => "rejected", "reason" => "invalid_attrs"} =
             ConsequencePredictor.predict(%{
               "action_contract" => %{
                 contract_id: "contract-1",
                 action: "read"
               },
               "action_preflight" => %{"preflight_id" => "preflight-1", "result" => "passed"}
             })
  end

  test "consequence predictions require explicit action contract and preflight" do
    assert %{"status" => "rejected", "reason" => "missing_action_contract"} =
             ConsequencePredictor.predict(%{})

    assert %{"status" => "rejected", "reason" => "missing_action_preflight"} =
             ConsequencePredictor.predict(%{
               "action_contract" => action_contract()
             })
  end

  test "consequence predictions reject invalid explicit field shapes" do
    assert %{"status" => "rejected", "reason" => "invalid_action_contract"} =
             ConsequencePredictor.predict(%{
               "action_contract" => Map.delete(action_contract(), "risk_level"),
               "action_preflight" => %{"preflight_id" => "preflight-1", "result" => "passed"}
             })

    assert %{"status" => "rejected", "reason" => "invalid_action_preflight"} =
             ConsequencePredictor.predict(%{
               "action_contract" => action_contract(),
               "action_preflight" => %{"preflight_id" => "preflight-1", "result" => "queued"}
             })
  end

  defp action_contract do
    %{
      "contract_id" => "contract-1",
      "action" => "write",
      "effect_scope" => "workspace_durable",
      "risk_level" => "high",
      "target_domain" => "workspace"
    }
  end
end
