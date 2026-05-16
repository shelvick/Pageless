defmodule PagelessWeb.Plugs.RawBodyReader do
  @moduledoc """
  Preserves the raw request body while delegating body reads to Plug.
  """

  import Plug.Conn, only: [assign: 3, put_private: 3]

  @chunk_key :raw_body_chunks

  @doc "Reads a request body chunk and stores the complete body on final read."
  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()}
          | {:more, binary(), Plug.Conn.t()}
          | {:error, term()}
          | {:error, term(), Plug.Conn.t()}
  def read_body(conn, opts) do
    conn = normalize_test_adapter(conn)

    case Plug.Conn.read_body(conn, opts) do
      {:ok, chunk, conn} ->
        body = build_body(conn, chunk)

        conn =
          conn
          |> clear_chunks()
          |> assign(:raw_body, body)

        {:ok, chunk, conn}

      {:more, chunk, conn} ->
        {:more, chunk, put_private(conn, @chunk_key, [chunk | chunks(conn)])}

      {:error, reason} ->
        if Map.has_key?(conn.private, @chunk_key) do
          {:error, reason, clear_chunks(conn)}
        else
          {:error, reason}
        end
    end
  end

  defp build_body(conn, final_chunk) do
    conn
    |> chunks()
    |> Enum.reverse()
    |> then(&IO.iodata_to_binary([&1, final_chunk]))
  end

  defp chunks(conn), do: Map.get(conn.private, @chunk_key, [])

  defp clear_chunks(conn), do: %{conn | private: Map.delete(conn.private, @chunk_key)}

  defp normalize_test_adapter(
         %Plug.Conn{adapter: {Plug.Adapters.Test.Conn, %{body: body} = state}} = conn
       ) do
    %{
      conn
      | adapter: {Plug.Adapters.Test.Conn, state |> Map.delete(:body) |> Map.put(:req_body, body)}
    }
  end

  defp normalize_test_adapter(conn), do: conn
end
