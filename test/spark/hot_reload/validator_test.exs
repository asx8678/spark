defmodule Spark.HotReload.ValidatorTest do
  use ExUnit.Case, async: true

  alias Spark.HotReload.Validator

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "spark_validator_test_#{:erlang.unique_integer()}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir}
  end

  describe "validate_prompt/1" do
    test "valid prompt file passes", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "orchestrator.md")
      File.write!(path, "# Orchestrator Prompt\nYou are the brain.")

      assert :ok = Validator.validate_prompt(path)
    end

    test "non-existent file rejected" do
      assert {:error, {:not_readable, _}} = Validator.validate_prompt("/nonexistent/prompt.md")
    end

    test "empty prompt file rejected", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "empty.md")
      File.write!(path, "")

      assert {:error, {:empty_file, _}} = Validator.validate_prompt(path)
    end
  end

  describe "validate_config/1" do
    test "valid config file passes", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "config.json")
      File.write!(path, Jason.encode!(%{"version" => 4.0, "llm" => %{"base_url" => "http://x"}}))

      assert :ok = Validator.validate_config(path)
    end

    test "invalid JSON rejected", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad_config.json")
      File.write!(path, "{not valid json!!!")

      assert {:error, {:invalid_json, _}} = Validator.validate_config(path)
    end

    test "non-JSON object rejected", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "array_config.json")
      File.write!(path, Jason.encode!([1, 2, 3]))

      assert {:error, {:invalid_config, _}} = Validator.validate_config(path)
    end

    test "non-existent config rejected" do
      assert {:error, {:not_readable, _}} = Validator.validate_config("/no/such/config.json")
    end
  end

  describe "validate_tool/1" do
    test "valid tool file passes", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "my_tool.ex")
      File.write!(path, """
      defmodule Spark.HotReload.ValidatorTest.MyTool do
        def name, do: "my_tool"
        def description, do: "A test tool"
        def schema, do: %{input: %{type: :string}}
        def risk, do: :low
        def execute(args, _ctx), do: {:ok, args}
      end
      """)

      assert :ok = Validator.validate_tool(path)
    after
      # Clean up the compiled module
      :code.delete(Spark.HotReload.ValidatorTest.MyTool)
      :code.purge(Spark.HotReload.ValidatorTest.MyTool)
    end

    test "tool without required callbacks rejected", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad_tool.ex")
      File.write!(path, """
      defmodule Spark.HotReload.ValidatorTest.BadTool do
        def name, do: "bad_tool"
      end
      """)

      assert {:error, {:missing_callbacks, _}} = Validator.validate_tool(path)
    after
      :code.delete(Spark.HotReload.ValidatorTest.BadTool)
      :code.purge(Spark.HotReload.ValidatorTest.BadTool)
    end

    test "tool with invalid risk rejected", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "invalid_risk_tool.ex")
      File.write!(path, """
      defmodule Spark.HotReload.ValidatorTest.InvalidRiskTool do
        def name, do: "invalid_risk"
        def description, do: "Bad risk"
        def schema, do: %{}
        def risk, do: :extreme
        def execute(args, _ctx), do: {:ok, args}
      end
      """)

      assert {:error, {:invalid_risk, :extreme}} = Validator.validate_tool(path)
    after
      :code.delete(Spark.HotReload.ValidatorTest.InvalidRiskTool)
      :code.purge(Spark.HotReload.ValidatorTest.InvalidRiskTool)
    end

    test "compilation error rejected", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "broken.ex")
      File.write!(path, "defmodule Broken do def broken(")

      assert {:error, {:compile_error, _}} = Validator.validate_tool(path)
    end
  end

  describe "validate_policy/1" do
    test "valid policy file passes", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "policy.json")
      File.write!(path, Jason.encode!(%{"allowed_tools" => ["read_file", "grep"]}))

      assert :ok = Validator.validate_policy(path)
    end

    test "invalid JSON policy rejected", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad_policy.json")
      File.write!(path, "not json at all")

      assert {:error, {:invalid_json, _}} = Validator.validate_policy(path)
    end

    test "non-object policy rejected", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "array_policy.json")
      File.write!(path, Jason.encode!([1, 2]))

      assert {:error, {:invalid_policy, _}} = Validator.validate_policy(path)
    end
  end

  describe "validate_guidance/1" do
    test "valid guidance file passes", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "after_edit.md")
      File.write!(path, "# After Edit Failure\nRe-read the file before retrying.")

      assert :ok = Validator.validate_guidance(path)
    end

    test "empty guidance file rejected", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "empty_guidance.md")
      File.write!(path, "")

      assert {:error, {:empty_file, _}} = Validator.validate_guidance(path)
    end

    test "non-existent guidance rejected" do
      assert {:error, {:not_readable, _}} = Validator.validate_guidance("/no/guidance.md")
    end
  end

  describe "validate_file/1" do
    test "auto-detects config from path", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "config.json")
      File.write!(path, Jason.encode!(%{"version" => 4.0}))

      assert :ok = Validator.validate_file(path)
    end

    test "auto-detects prompt from path", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "prompts")
      File.mkdir_p!(path)
      prompt_path = Path.join(path, "worker.md")
      File.write!(prompt_path, "You are a coding worker.")

      assert :ok = Validator.validate_file(prompt_path)
    end

    test "auto-detects guidance from path", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "guidance")
      File.mkdir_p!(path)
      guidance_path = Path.join(path, "after_grep.md")
      File.write!(guidance_path, "Inspect surrounding code.")

      assert :ok = Validator.validate_file(guidance_path)
    end

    test "unknown path type rejected", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "unknown.xyz")
      File.write!(path, "mystery content")

      assert {:error, {:unknown_type, _}} = Validator.validate_file(path)
    end
  end
end
