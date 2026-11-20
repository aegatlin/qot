defmodule Qot.TranscriptionTest do
  use Qot.DataCase, async: false

  alias Qot.Accounts
  alias Qot.Transcription

  test "a recording counts for what the client says, rounded up" do
    assert Transcription.billable_seconds(10_000, 4_200) == 5
  end

  test "but never for less than its size allows" do
    # 1.6 MB can't be under 100 seconds at 128 kbit/s.
    assert Transcription.billable_seconds(1_600_000, 1_000) == 100
    assert Transcription.billable_seconds(1_600_000, nil) == 100
  end

  test "and for at least a second" do
    assert Transcription.billable_seconds(10, nil) == 1
    assert Transcription.billable_seconds(10, -5) == 1
  end

  test "each month has its own allowance" do
    {:ok, user} = Accounts.create_user(%{email: "m@example.com"})
    {:ok, _} = Accounts.set_plan("m@example.com", "plus")

    assert {:ok, _} = Transcription.transcribe(user.id, "a", "memo.m4a", 60_000, ~D[2026-11-30])

    assert {:error, :allowance_used} =
             Transcription.transcribe(user.id, "a", "memo.m4a", 1_000, ~D[2026-11-30])

    assert {:ok, _} = Transcription.transcribe(user.id, "a", "memo.m4a", 1_000, ~D[2026-12-01])
    assert Transcription.used_seconds(user.id, ~D[2026-11-15]) == 60
    assert Transcription.used_seconds(user.id, ~D[2026-12-15]) == 1
  end

  test "without a provider configured it is unavailable to everyone" do
    {:ok, user} = Accounts.create_user(%{email: "u@example.com"})
    {:ok, _} = Accounts.set_plan("u@example.com", "plus")
    config = Application.get_env(:qot, :transcription)
    Application.delete_env(:qot, :transcription)
    on_exit(fn -> Application.put_env(:qot, :transcription, config) end)

    refute Transcription.available?()
    assert {:error, :unavailable} = Transcription.transcribe(user.id, "a", "memo.m4a", nil)
  end

  test "a plan is free or plus, and set by the account's email" do
    {:ok, _} = Accounts.create_user(%{email: "p@example.com"})
    assert {:ok, %{plan: "plus"}} = Accounts.set_plan("P@Example.com", "plus")
    assert {:ok, %{plan: "free"}} = Accounts.set_plan("p@example.com", "free")
    assert {:error, :unknown_plan} = Accounts.set_plan("p@example.com", "gold")
    assert {:error, :not_found} = Accounts.set_plan("nobody@example.com", "plus")
  end

  test "deleting the account deletes its usage" do
    {:ok, user} = Accounts.create_user(%{email: "d@example.com"})
    {:ok, _} = Accounts.set_plan("d@example.com", "plus")
    {:ok, _} = Transcription.transcribe(user.id, "a", "memo.m4a", 2_000)
    :ok = Accounts.delete_user(user.id)
    assert Qot.Repo.aggregate(Qot.Transcription.Usage, :count) == 0
  end
end
