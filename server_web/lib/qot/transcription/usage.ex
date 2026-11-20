defmodule Qot.Transcription.Usage do
  @moduledoc "Seconds of audio an account had transcribed in one month (UTC)."
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id

  schema "transcription_usage" do
    field(:user_id, :binary_id, primary_key: true)
    field(:month, :date, primary_key: true)
    field(:seconds, :integer, default: 0)
  end
end
