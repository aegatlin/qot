defmodule Qot.CoreTest do
  # Replays core/tests/vectors/server.json through the NIF: the same cases
  # the Rust core is tested with (core/tests/server_vectors.rs).
  use ExUnit.Case, async: true

  alias Qot.Core

  @vectors Path.expand("../../../core/tests/vectors/server.json", __DIR__)
  @external_resource @vectors
  @cases @vectors |> File.read!() |> Jason.decode!() |> Map.fetch!("cases")

  defp log(c), do: Enum.map(c["log"], &Base.decode64!/1)

  test "there are vectors to replay" do
    assert length(@cases) >= 6
  end

  for c <- @cases do
    @c c

    test "#{c["name"]}: read" do
      assert {:ok, note} = Core.read(log(@c))
      expected = @c["read"]
      assert note.id == expected["id"]
      assert note.content == expected["content"]
      assert note.deleted == expected["deleted"]
      assert [_ | _] = note.heads

      seen =
        Enum.map(note.attachments, fn a ->
          a |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
        end)

      assert seen == expected["attachments"]
    end

    if c["fill"] do
      test "#{c["name"]}: fill_text" do
        fill = @c["fill"]
        log = log(@c)
        assert {:ok, change} = Core.fill_text(log, fill["attachment"], fill["text"])
        assert is_binary(change) == fill["changes"]

        # The change is one more entry in the log, like any device's.
        log = if change, do: log ++ [change], else: log
        assert {:ok, note} = Core.read(log)
        assert note.content == fill["content"]

        if change do
          assert Enum.find(note.attachments, &(&1.id == fill["attachment"])).text == "done"
          # Asked again (a retry, a second worker), nothing more is written.
          assert {:ok, nil} = Core.fill_text(log, fill["attachment"], fill["text"])
        end

        if fill["meanwhile"] do
          meanwhile = Base.decode64!(fill["meanwhile"])
          # In either order of arrival.
          for both <- [log ++ [meanwhile], List.insert_at(log, -2, meanwhile)] do
            assert {:ok, note} = Core.read(both)
            assert note.content in fill["content_with_both"]
          end
        end
      end
    end
  end

  test "bytes that are not a note are an error, not a crash" do
    assert {:error, reason} = Core.read(["not automerge"])
    assert is_binary(reason)
    assert {:error, _} = Core.read([])
    assert {:error, _} = Core.fill_text(["nope"], "id", "text")
  end

  test "an attachment the note doesn't have is an error" do
    c = Enum.find(@cases, &(&1["fill"] != nil))
    assert {:error, reason} = Core.fill_text(log(c), "0199a7e2-0000-7000-8000-000000000000", "x")
    assert reason =~ "no attachment"
  end
end
