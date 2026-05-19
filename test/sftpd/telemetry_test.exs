defmodule Sftpd.TelemetryTest do
  use ExUnit.Case, async: false

  alias Sftpd.Telemetry
  alias Sftpd.Test.TelemetryHelper

  describe "span/4" do
    test "emits measurements and merged metadata for successful calls" do
      handler_id = TelemetryHelper.attach(self(), [[:sftpd, :test, :success]])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      result =
        Telemetry.span(
          [:sftpd, :test, :success],
          %{base: :metadata},
          fn -> {:ok, "value"} end,
          fn {:ok, value}, duration ->
            {%{duration: duration, bytes: byte_size(value)}, %{result: :ok, value: value}}
          end
        )

      assert result == {:ok, "value"}

      assert_receive {:telemetry_event, [:sftpd, :test, :success], measurements, metadata}
      assert is_integer(measurements.duration)
      assert measurements.bytes == 5
      assert metadata.base == :metadata
      assert metadata.result == :ok
      assert metadata.value == "value"
    end

    test "emits exception metadata and reraises" do
      handler_id = TelemetryHelper.attach(self(), [[:sftpd, :test, :exception]])
      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert_raise RuntimeError, "boom", fn ->
        Telemetry.span([:sftpd, :test, :exception], %{base: :metadata}, fn ->
          raise "boom"
        end)
      end

      assert_receive {:telemetry_event, [:sftpd, :test, :exception], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.base == :metadata
      assert metadata.result == :exception
      assert metadata.kind == :error
      assert %RuntimeError{message: "boom"} = metadata.reason
    end
  end
end
