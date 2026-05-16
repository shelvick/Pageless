defmodule PagelessWeb.Plugs.RawBodyReaderTest.ErrorAdapter do
  @moduledoc "Test adapter that forces Plug.Conn.read_body/2 to return an error tuple."

  @doc false
  @spec read_req_body(map(), keyword()) :: {:error, term()}
  def read_req_body(%{reason: reason}, _opts), do: {:error, reason}
end

defmodule PagelessWeb.Plugs.RawBodyReaderTest do
  @moduledoc "Tests raw request-body preservation for HMAC verification."

  use ExUnit.Case, async: true

  import Plug.Test

  alias PagelessWeb.Plugs.RawBodyReader
  alias PagelessWeb.Plugs.RawBodyReaderTest.ErrorAdapter

  describe "read_body/2" do
    test "assigns single-chunk body to conn.assigns[:raw_body]" do
      conn = conn(:post, "/webhook/pagerduty-events-v2", ~s({"id":"evt-1"}))

      assert {:ok, body, conn} = RawBodyReader.read_body(conn, [])
      assert body == ~s({"id":"evt-1"})
      assert conn.assigns.raw_body == ~s({"id":"evt-1"})
    end

    test "accumulates and concatenates multi-chunk bodies in order" do
      conn = conn(:post, "/webhook/pagerduty-events-v2", "chunk1chunk2chunk3")

      assert {:more, "chunk1", conn} = RawBodyReader.read_body(conn, length: 6)
      assert {:more, "chunk2", conn} = RawBodyReader.read_body(conn, length: 6)
      assert {:ok, "chunk3", conn} = RawBodyReader.read_body(conn, length: 6)

      assert conn.assigns.raw_body == "chunk1chunk2chunk3"
    end

    test "assigns empty body as empty binary" do
      conn = conn(:post, "/webhook/pagerduty-events-v2", "")

      assert {:ok, "", conn} = RawBodyReader.read_body(conn, [])
      assert conn.assigns.raw_body == ""
    end

    test "propagates :error tuples without setting the assign" do
      conn = %{
        conn(:post, "/webhook/pagerduty-events-v2", "body")
        | adapter: {ErrorAdapter, %{reason: :timeout}}
      }

      assert {:error, :timeout} = RawBodyReader.read_body(conn, [])
      refute Map.has_key?(conn.assigns, :raw_body)
    end

    test "propagates mid-stream :error and does not leak private state" do
      conn = conn(:post, "/webhook/pagerduty-events-v2", "partial")

      assert {:more, "part", conn} = RawBodyReader.read_body(conn, length: 4)
      assert Map.has_key?(conn.private, :raw_body_chunks)

      error_conn = %{conn | adapter: {ErrorAdapter, %{reason: :closed}}}
      assert {:error, :closed, errored_conn} = RawBodyReader.read_body(error_conn, length: 4)
      refute Map.has_key?(errored_conn.private, :raw_body_chunks)
      refute Map.has_key?(errored_conn.assigns, :raw_body)

      resumed_conn = %{errored_conn | adapter: {Plug.Adapters.Test.Conn, %{body: "fresh"}}}
      assert {:ok, "fresh", resumed_conn} = RawBodyReader.read_body(resumed_conn, [])
      assert resumed_conn.assigns.raw_body == "fresh"
    end

    test "clears the private chunk-accumulator after final :ok" do
      conn = conn(:post, "/webhook/pagerduty-events-v2", "abc123")

      assert {:more, "abc", conn} = RawBodyReader.read_body(conn, length: 3)
      assert {:ok, "123", conn} = RawBodyReader.read_body(conn, length: 3)

      assert conn.assigns.raw_body == "abc123"
      refute Map.has_key?(conn.private, :raw_body_chunks)
    end
  end
end
