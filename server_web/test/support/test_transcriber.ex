defmodule Qot.TestTranscriber do
  @moduledoc """
  The speech-to-text provider in tests: "hears" the bytes as text, fails
  for the bytes `"static"`, and tells the test process what it was given.
  """
  @behaviour Qot.Transcription.Provider

  @impl true
  def transcribe("static", _filename, _config), do: {:error, {:status, 500}}

  def transcribe(bytes, filename, _config) do
    send(self(), {:transcribed, bytes, filename})
    {:ok, "  heard #{bytes}\n"}
  end
end
