defmodule Pageless.DeployCaddyfileTest do
  @moduledoc "Tests reverse-proxy webhook allowlist contract."

  use ExUnit.Case, async: true

  test "Caddy gates webhook routes by env-templated sender IP" do
    caddyfile = File.read!("deploy/Caddyfile")

    assert caddyfile =~ "@webhooks path /webhook/*"
    assert caddyfile =~ "@allowed_sender client_ip {$VKE_EGRESS_IP}"
    assert caddyfile =~ "handle @allowed_sender"
    assert caddyfile =~ "reverse_proxy 127.0.0.1:4040"
    assert caddyfile =~ ~s(respond "" 403)
    refute caddyfile =~ "reverse_proxy 127.0.0.1:4000"
    refute caddyfile =~ ~r/client_ip \d+\.\d+\.\d+\.\d+/
  end
end
