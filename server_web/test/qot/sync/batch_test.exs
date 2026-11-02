defmodule Qot.Sync.BatchTest do
  use ExUnit.Case, async: true

  alias Qot.Sync.Batch

  @note_id "0199a7e2-5c3b-7c4e-9a1d-2f6b8e4d3c21"

  defp change(note_id \\ @note_id, data \\ "change-bytes"),
    do: %{"note_id" => note_id, "data" => Base.encode64(data)}

  describe "parse_push/1" do
    test "decodes changes in order" do
      assert {:ok, [%{note_id: @note_id, data: "a"}, %{note_id: @note_id, data: "b"}]} =
               Batch.parse_push(%{"changes" => [change(@note_id, "a"), change(@note_id, "b")]})
    end

    test "normalises note ids to lowercase" do
      upper = String.upcase(@note_id)
      assert {:ok, [%{note_id: @note_id}]} = Batch.parse_push(%{"changes" => [change(upper)]})
    end

    test "rejects a missing or empty batch" do
      assert {:error, _} = Batch.parse_push(%{})
      assert {:error, _} = Batch.parse_push(%{"changes" => []})
      assert {:error, _} = Batch.parse_push(%{"changes" => "nope"})
    end

    test "rejects a batch over the size limit" do
      changes = List.duplicate(change(), Batch.max_changes() + 1)
      assert {:error, message} = Batch.parse_push(%{"changes" => changes})
      assert message =~ "at most"
    end

    test "rejects a bad note id, bad base64, empty or oversized data" do
      assert {:error, _} = Batch.parse_push(%{"changes" => [change("not-a-uuid")]})

      assert {:error, _} =
               Batch.parse_push(%{"changes" => [%{"note_id" => @note_id, "data" => "%%%"}]})

      assert {:error, _} = Batch.parse_push(%{"changes" => [change(@note_id, "")]})

      big = :binary.copy("x", Batch.max_change_bytes() + 1)
      assert {:error, _} = Batch.parse_push(%{"changes" => [change(@note_id, big)]})
    end

    test "one bad change rejects the whole batch" do
      assert {:error, _} =
               Batch.parse_push(%{"changes" => [change(), change("not-a-uuid")]})
    end
  end

  describe "parse_pull/1" do
    test "defaults to everything from the start" do
      assert {:ok, %{since: 0, limit: limit}} = Batch.parse_pull(%{})
      assert limit == Batch.default_limit()
    end

    test "reads since and limit, clamping limit" do
      assert {:ok, %{since: 42, limit: 10}} =
               Batch.parse_pull(%{"since" => "42", "limit" => "10"})

      assert {:ok, %{limit: max}} = Batch.parse_pull(%{"limit" => "999999"})
      assert max == Batch.max_limit()
      assert {:ok, %{limit: 1}} = Batch.parse_pull(%{"limit" => "0"})
    end

    test "rejects a negative or non-numeric cursor" do
      assert {:error, _} = Batch.parse_pull(%{"since" => "-1"})
      assert {:error, _} = Batch.parse_pull(%{"since" => "abc"})
      assert {:error, _} = Batch.parse_pull(%{"limit" => "abc"})
    end
  end

  describe "number/2" do
    test "assigns consecutive seqs ending at the new last seq" do
      entries = [%{note_id: "a", data: "1"}, %{note_id: "b", data: "2"}]

      assert [%{seq: 9, note_id: "a"}, %{seq: 10, note_id: "b"}] = Batch.number(entries, 10)
    end
  end
end
