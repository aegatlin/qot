defmodule Qot.Core do
  @moduledoc """
  `qot_core`, the note model every client uses, for the server: a Rustler
  NIF (`core_nif/`, the crate `qot_nif`). This is how the server reads and
  edits a note with the same rules as the clients, as a peer
  (`docs/records/2026-11-20-pipelines-before-encryption.md`).

  The server holds a note as its changes in the account's log, so every
  function takes them, in the log's order. Functions run on dirty CPU
  schedulers.

  In dev and test Rustler compiles the crate with the local Rust. A
  release image builds `libqot_nif.so` in its own Rust stage and puts it in
  `priv/native/`, and `QOT_NIF_PREBUILT=1` at compile time says to load
  that instead of compiling.
  """

  use Rustler,
    otp_app: :qot,
    crate: "qot_nif",
    path: "../core_nif",
    skip_compilation?: System.get_env("QOT_NIF_PREBUILT") == "1"

  @type attachment :: %{
          id: String.t(),
          kind: String.t(),
          media_type: String.t(),
          size: non_neg_integer(),
          duration_ms: non_neg_integer() | nil,
          text: String.t()
        }

  @type note :: %{
          id: String.t(),
          content: String.t(),
          deleted: boolean(),
          heads: [String.t()],
          attachments: [attachment()]
        }

  @doc "The note these changes make."
  @spec read([binary()]) :: {:ok, note()} | {:error, String.t()}
  def read(_changes), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Writes an attachment's text into the note, once, under any text already
  there. Returns the change to append to the log, or `{:ok, nil}` when the
  attachment wasn't waiting for text.
  """
  @spec fill_text([binary()], String.t(), String.t()) ::
          {:ok, binary() | nil} | {:error, String.t()}
  def fill_text(_changes, _attachment_id, _text), do: :erlang.nif_error(:nif_not_loaded)
end
