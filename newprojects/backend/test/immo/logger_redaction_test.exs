defmodule Immo.LoggerRedactionTest do
  @moduledoc """
  P1-E5.1 — §10.1 / §13 Logger redaction acceptance.

  Verifies that the `Immo.LoggerRedaction` filter scrubs token-shaped
  content from log lines. The redaction rules are tested in isolation
  here (no Logger machinery) so the test is fast and deterministic.
  """

  use ExUnit.Case, async: true

  alias Immo.LoggerRedaction

  @secret_token "supersecret-0000000000000000000000000000000000000000"

  describe "scrub/1: authorization header" do
    test "Bearer scheme → [REDACTED]" do
      str = "authorization: Bearer #{@secret_token}"
      refute scrubbed(str) =~ @secret_token
      assert scrubbed(str) =~ "authorization: Bearer [REDACTED]"
    end

    test "case-insensitive header name" do
      str = "Authorization: Bearer #{@secret_token}"
      refute scrubbed(str) =~ @secret_token
    end

    test "AUTHORIZATION (uppercase) header" do
      str = "AUTHORIZATION= Bearer #{@secret_token}"
      refute scrubbed(str) =~ @secret_token
    end

    test "header without Bearer scheme" do
      str = "authorization: #{@secret_token}"
      refute scrubbed(str) =~ @secret_token
    end

    test "quoted header value (HTTP wire format)" do
      str = ~s(authorization: "#{@secret_token}")
      refute scrubbed(str) =~ @secret_token
    end
  end

  describe "scrub/1: JSON body fields" do
    test "authorization field in JSON" do
      str = ~s({"authorization": "#{@secret_token}", "user": "alice"})
      refute scrubbed(str) =~ @secret_token
      assert scrubbed(str) =~ ~s("authorization": "[REDACTED]")
    end

    test "token field in JSON" do
      str = ~s({"token": "#{@secret_token}"})
      refute scrubbed(str) =~ @secret_token
      assert scrubbed(str) =~ ~s("token": "[REDACTED]")
    end

    test "x-api-token field in JSON" do
      str = ~s({"x-api-token": "#{@secret_token}"})
      refute scrubbed(str) =~ @secret_token
    end
  end

  describe "scrub/1: query strings (defensive)" do
    test "?token=... pattern" do
      str = "GET /api/v1/projects?token=#{@secret_token}&limit=10"
      refute scrubbed(str) =~ @secret_token
      assert scrubbed(str) =~ "token=[REDACTED]"
    end

    test "?access_token=... pattern" do
      str = "GET /api?access_token=#{@secret_token}"
      refute scrubbed(str) =~ @secret_token
    end
  end

  describe "scrub/1: does not break legitimate content" do
    test "preserves non-token content" do
      str = "user logged in from 192.168.1.1"
      assert scrubbed(str) == str
    end

    test "preserves user IDs and slugs" do
      str = "developer=immo-atlas slug=le-jardin-de-l-atlantique"
      assert scrubbed(str) == str
    end

    test "preserves currency/price content" do
      str = "listing price=1250000 MAD currency=MAD"
      assert scrubbed(str) == str
    end
  end

  describe "filtering/1: log event passthrough" do
    test "passes through non-string log events unchanged" do
      event = %{level: :info, msg: {:report, %{foo: :bar}}}
      assert LoggerRedaction.filtering(event) == event
    end

    test "scrubs string msg payload" do
      event = %{
        level: :info,
        msg: {:string, "authorization: Bearer #{@secret_token}"}
      }

      scrubbed_event = LoggerRedaction.filtering(event)
      {:string, scrubbed_str} = scrubbed_event.msg
      refute scrubbed_str =~ @secret_token
    end
  end

  defp scrubbed(str), do: LoggerRedaction.scrub(str)
end
