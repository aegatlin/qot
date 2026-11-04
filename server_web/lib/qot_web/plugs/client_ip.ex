defmodule QotWeb.Plugs.ClientIP do
  @moduledoc """
  Assigns `:client_ip`, the address of the client rather than of the proxy
  in front of the server.

  Behind a proxy, `conn.remote_ip` is the proxy. `config :qot,
  :client_ip_header` names the header the proxy sets to the client's address
  (on Railway, `x-real-ip`, which its edge proxy overwrites on every
  request). Only name a header the proxy always sets: a client can send any
  header it likes. Unset, or if the header is missing or unparsable, the
  peer address is used.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    header = Application.get_env(:qot, :client_ip_header)
    Plug.Conn.assign(conn, :client_ip, from(conn.remote_ip, conn.req_headers, header))
  end

  @doc "The client's address, given the peer address and request headers."
  @spec from(:inet.ip_address(), [{String.t(), String.t()}], String.t() | nil) ::
          :inet.ip_address()
  def from(remote_ip, _headers, nil), do: remote_ip

  def from(remote_ip, headers, header) do
    with {_, value} <- List.keyfind(headers, header, 0),
         {:ok, ip} <-
           value |> String.trim() |> String.to_charlist() |> :inet.parse_strict_address() do
      ip
    else
      _ -> remote_ip
    end
  end
end
