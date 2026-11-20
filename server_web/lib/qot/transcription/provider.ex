defmodule Qot.Transcription.Provider do
  @moduledoc """
  The speech-to-text service: anything with OpenAI's
  `/v1/audio/transcriptions` shape (a multipart upload with `file` and
  `model`, a bearer key, `{"text": …}` back). Which one is configuration
  (`STT_API_URL`, `STT_API_KEY`, `STT_MODEL`). Tests use
  `Qot.TestTranscriber`, never a real service.
  """

  require Logger

  @callback transcribe(bytes :: binary(), filename :: String.t(), config :: map()) ::
              {:ok, String.t()} | {:error, term()}

  @behaviour __MODULE__

  @impl true
  def transcribe(bytes, filename, %{url: url, key: key, model: model} = config) do
    options = [
      auth: {:bearer, key},
      form_multipart: [model: model, file: {bytes, filename: filename}],
      receive_timeout: 120_000,
      retry: false
    ]

    # `req_options` is for tests, which answer in the provider's place.
    result = Req.post(url, options ++ Map.get(config, :req_options, []))

    case result do
      {:ok, %Req.Response{status: 200, body: %{"text" => text}}} when is_binary(text) ->
        {:ok, text}

      # The body may quote what was said, so only the status is logged.
      {:ok, %Req.Response{status: status}} ->
        Logger.warning("The transcription provider answered #{status}")
        {:error, {:status, status}}

      {:error, error} ->
        Logger.warning("The transcription provider wasn't reached: #{Exception.message(error)}")
        {:error, :unreachable}
    end
  end
end
