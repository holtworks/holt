defmodule Holt.ResearchClaimsTest do
  use ExUnit.Case

  alias Holt.{ResearchClaims, Workspace}

  test "research claim recording is explicit and canonical" do
    workspace = tmp_workspace()
    Workspace.init(workspace)

    claim_params =
      %{
        "query" => "holt docs",
        "claim" => "Holt has docs.",
        "source_type" => "official_docs",
        "version_applies" => "2026-05-18",
        "confidence" => 0.9
      }

    assert ResearchClaims.maybe_record(
             "search_web",
             claim_params,
             [workspace: workspace],
             %{"text" => "Evidence"}
           ) == {:ok, %{"research_claim_saved" => false}}

    assert ResearchClaims.list(workspace: workspace) == []

    assert {:error, %{"field" => "params"}} =
             ResearchClaims.validate_recording_request(%{save_research_claim: true})

    assert {:error, %{"field" => "confidence"}} =
             ResearchClaims.validate_recording_request(
               Map.put(claim_params, "save_research_claim", true)
               |> Map.delete("confidence")
             )

    assert {:ok, %{"research_claim_saved" => true, "research_claim" => claim}} =
             ResearchClaims.maybe_record(
               "search_web",
               claim_params
               |> Map.put("save_research_claim", true)
               |> Map.put("ref", "TASK-1"),
               [workspace: workspace],
               %{
                 "text" => "Evidence",
                 "results" => [%{"url" => "https://holtworks.ai/docs"}]
               }
             )

    assert claim["source_type"] == "official_docs"
    assert claim["version_applies"] == "2026-05-18"
    assert claim["confidence"] == 0.9
    assert claim["source"]["urls"] == ["https://holtworks.ai/docs"]
    refute Map.has_key?(claim, "task_ref")

    assert [stored_claim] = ResearchClaims.list(workspace: workspace)
    assert stored_claim["id"] == claim["id"]
  end

  defp tmp_workspace do
    Path.join(System.tmp_dir!(), "holt-research-#{random_id()}")
  end

  defp random_id, do: Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
end
