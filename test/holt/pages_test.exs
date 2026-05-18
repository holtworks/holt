defmodule Holt.PagesTest do
  use ExUnit.Case

  alias Holt.{Pages, Workspace}

  test "page actions require canonical explicit identifiers" do
    workspace = tmp_workspace()
    Workspace.init(workspace)

    assert {:ok, %{"page" => page}} =
             Pages.create(
               %{"page_type" => "document", "title" => "Spec", "content" => "Initial"},
               workspace: workspace
             )

    assert File.read!(Path.join(workspace, page["document_path"])) == "Initial"

    assert Pages.create(%{page_type: "document", title: "Spec"}, workspace: workspace) ==
             {:error, :invalid_page_attrs}

    assert Pages.set_title(%{"id" => page["id"], "title" => "Spec v2"}, workspace: workspace) ==
             {:error, {:missing_required, "page_id"}}

    assert Pages.write_document(%{"action" => "insert_below", "content" => "More"},
             workspace: workspace
           ) == {:error, {:missing_required, "page_id"}}

    assert Pages.write_document(
             %{page_id: page["id"], action: "insert_below", content: "More"},
             workspace: workspace
           ) == {:error, :invalid_page_attrs}

    assert {:ok, %{"page" => titled_page}} =
             Pages.set_title(
               %{"page_id" => page["id"], "title" => "Spec v2"},
               workspace: workspace
             )

    assert titled_page["title"] == "Spec v2"

    assert {:ok, %{"document_event" => event}} =
             Pages.write_document(
               %{"page_id" => page["id"], "action" => "insert_below", "content" => "More"},
               workspace: workspace
             )

    assert event["edit_status"] == "inserted_below"
    assert File.read!(Path.join(workspace, page["document_path"])) == "Initial\n\nMore"
  end

  defp tmp_workspace do
    Path.join(System.tmp_dir!(), "holt-pages-#{random_id()}")
  end

  defp random_id, do: Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
end
