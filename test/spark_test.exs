defmodule SparkTest do
  use ExUnit.Case

  test "app identity" do
    assert :spark |> Application.spec(:vsn) |> List.to_string() == "4.0.0"
  end
end
