defmodule Qot.Transcription do
  @moduledoc """
  Speech to text for a client that can't do it itself, through a cloud
  provider (`docs/records/2026-11-20-paid-transcription.md`). The client
  sends one recording and gets its text back; the server keeps neither,
  only how many seconds the account has used this month. The client
  writes the text into the note, so the server still never reads or writes
  notes.

  It is a paid feature (the `plus` plan), with a monthly allowance, and
  off entirely unless a provider is configured (`config :qot,
  :transcription`).
  """

  import Ecto.Query

  alias Qot.Accounts.User
  alias Qot.Repo
  alias Qot.Transcription.Usage

  @type refusal ::
          :unknown_user | :plan_required | :unavailable | :allowance_used | :provider_failed

  @doc """
  The text of the recording in `bytes`. `filename` tells the provider the
  format by its extension; `stated_ms` is how long the client says it is.

  The seconds are taken from the allowance before the provider is asked
  and given back if it fails, so two requests at once can't both use the
  last minute.
  """
  @spec transcribe(String.t(), binary(), String.t(), integer() | nil, Date.t()) ::
          {:ok, String.t()} | {:error, refusal()}
  def transcribe(user_id, bytes, filename, stated_ms, today \\ Date.utc_today()) do
    seconds = billable_seconds(byte_size(bytes), stated_ms)
    month = Date.beginning_of_month(today)

    with {:ok, config} <- config(),
         :ok <- reserve(user_id, month, seconds, config.monthly_seconds) do
      case config.api.transcribe(bytes, filename, config) do
        {:ok, text} ->
          {:ok, String.trim(text)}

        {:error, _reason} ->
          add(user_id, month, -seconds)
          {:error, :provider_failed}
      end
    end
  end

  @doc """
  The seconds a recording counts for: what the client says, but never less
  than its size allows at 128 kbit/s, so a client can't claim a long
  recording is short. At least one.
  """
  @spec billable_seconds(non_neg_integer(), integer() | nil) :: pos_integer()
  def billable_seconds(bytes, stated_ms) do
    stated = if is_integer(stated_ms) and stated_ms > 0, do: ceil(stated_ms / 1000), else: 0
    Enum.max([stated, ceil(bytes / 16_000), 1])
  end

  @doc "Seconds the account has used in the month of `today`."
  def used_seconds(user_id, today \\ Date.utc_today()) do
    month = Date.beginning_of_month(today)

    Repo.one(
      from(u in Usage, where: u.user_id == ^user_id and u.month == ^month, select: u.seconds)
    ) ||
      0
  end

  @doc "Whether a provider is configured."
  def available?, do: match?({:ok, _}, config())

  defp config do
    case Application.get_env(:qot, :transcription) do
      %{api: _, monthly_seconds: _} = config -> {:ok, config}
      _ -> {:error, :unavailable}
    end
  end

  # Under the user row's lock, like the blob quota.
  defp reserve(user_id, month, seconds, limit) do
    {:ok, result} =
      Repo.transaction(fn ->
        plan =
          Repo.one(from(u in User, where: u.id == ^user_id, lock: "FOR UPDATE", select: u.plan))

        cond do
          plan == nil -> {:error, :unknown_user}
          not User.transcribes?(plan) -> {:error, :plan_required}
          used_seconds(user_id, month) + seconds > limit -> {:error, :allowance_used}
          true -> add(user_id, month, seconds)
        end
      end)

    result
  end

  defp add(user_id, month, seconds) do
    Repo.insert_all(Usage, [%{user_id: user_id, month: month, seconds: seconds}],
      on_conflict: [inc: [seconds: seconds]],
      conflict_target: [:user_id, :month]
    )

    :ok
  end
end
