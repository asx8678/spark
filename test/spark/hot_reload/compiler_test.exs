defmodule Spark.HotReload.CompilerTest do
  use ExUnit.Case, async: true

  alias Spark.HotReload.Compiler

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "spark_compiler_test_#{:erlang.unique_integer()}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir}
  end

  describe "compile_tool/1" do
    test "compiles a valid tool module", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "good_tool.ex")

      File.write!(path, """
      defmodule Spark.HotReload.CompilerTest.GoodTool do
        def name, do: "good_tool"
        def description, do: "A well-behaved tool"
        def schema, do: %{path: %{type: :string, required: true}}
        def risk, do: :medium
        def execute(args, _ctx), do: {:ok, args}
      end
      """)

      assert {:ok, module} = Compiler.compile_tool(path)
      assert module == Spark.HotReload.CompilerTest.GoodTool
      assert module.name() == "good_tool"
    after
      :code.delete(Spark.HotReload.CompilerTest.GoodTool)
      :code.purge(Spark.HotReload.CompilerTest.GoodTool)
    end

    test "rejects tool missing name callback", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "no_name_tool.ex")

      File.write!(path, """
      defmodule Spark.HotReload.CompilerTest.NoNameTool do
        def description, do: "No name"
        def schema, do: %{}
        def risk, do: :low
        def execute(_args, _ctx), do: {:ok, nil}
      end
      """)

      assert {:error, {:missing_callback, {_, :name, 0}}} = Compiler.compile_tool(path)
    after
      :code.delete(Spark.HotReload.CompilerTest.NoNameTool)
      :code.purge(Spark.HotReload.CompilerTest.NoNameTool)
    end

    test "rejects tool with non-string name", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad_name_tool.ex")

      File.write!(path, """
      defmodule Spark.HotReload.CompilerTest.BadNameTool do
        def name, do: :not_a_string
        def description, do: "Bad name"
        def schema, do: %{}
        def risk, do: :low
        def execute(_args, _ctx), do: {:ok, nil}
      end
      """)

      assert {:error, {:invalid_name, :not_a_string}} = Compiler.compile_tool(path)
    after
      :code.delete(Spark.HotReload.CompilerTest.BadNameTool)
      :code.purge(Spark.HotReload.CompilerTest.BadNameTool)
    end

    test "rejects tool with non-map schema", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad_schema_tool.ex")

      File.write!(path, """
      defmodule Spark.HotReload.CompilerTest.BadSchemaTool do
        def name, do: "bad_schema"
        def description, do: "Bad schema"
        def schema, do: [:not, :a, :map]
        def risk, do: :low
        def execute(_args, _ctx), do: {:ok, nil}
      end
      """)

      assert {:error, {:invalid_schema, _}} = Compiler.compile_tool(path)
    after
      :code.delete(Spark.HotReload.CompilerTest.BadSchemaTool)
      :code.purge(Spark.HotReload.CompilerTest.BadSchemaTool)
    end

    test "rejects tool with invalid risk level", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad_risk_tool.ex")

      File.write!(path, """
      defmodule Spark.HotReload.CompilerTest.BadRiskTool do
        def name, do: "bad_risk"
        def description, do: "Bad risk"
        def schema, do: %{}
        def risk, do: :extreme
        def execute(_args, _ctx), do: {:ok, nil}
      end
      """)

      assert {:error, {:invalid_risk, :extreme}} = Compiler.compile_tool(path)
    after
      :code.delete(Spark.HotReload.CompilerTest.BadRiskTool)
      :code.purge(Spark.HotReload.CompilerTest.BadRiskTool)
    end

    test "rejects tool with syntax error", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "syntax_error.ex")
      File.write!(path, "defmodule Broken do def bad(")

      assert {:error, {:compile_error, _}} = Compiler.compile_tool(path)
    end

    test "rejects non-existent file" do
      assert {:error, {:read_error, :enoent}} = Compiler.compile_tool("/nonexistent/tool.ex")
    end
  end

  describe "compile_module/1" do
    test "rejects unsafe module names", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "io_hack.ex")

      File.write!(path, """
      defmodule IO.Hacked do
        def evil, do: :yes
      end
      """)

      assert {:error, {:unsafe_module, _}} = Compiler.compile_module(path)
    end

    test "rejects module not in allowlist", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "unknown_module.ex")

      File.write!(path, """
      defmodule Spark.HotReload.CompilerTest.UnknownModule do
        def hello, do: :world
      end
      """)

      assert {:error, {:not_in_allowlist, _}} = Compiler.compile_module(path)
    after
      :code.delete(Spark.HotReload.CompilerTest.UnknownModule)
      :code.purge(Spark.HotReload.CompilerTest.UnknownModule)
    end

    test "rejects System module prefix", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "system_hack.ex")

      File.write!(path, """
      defmodule System.Hacked do
        def evil, do: :yes
      end
      """)

      assert {:error, {:unsafe_module, _}} = Compiler.compile_module(path)
    end
  end

  describe "safe_module?/1" do
    test "Spark.Config is in safe list" do
      assert Compiler.safe_module?(Spark.Config)
    end

    test "Spark.Dispatcher is in safe list" do
      assert Compiler.safe_module?(Spark.Dispatcher)
    end

    test "Unknown module is not in safe list" do
      refute Compiler.safe_module?(Spark.HotReload.CompilerTest.Unknown)
    end
  end

  describe "unsafe_module_name?/1" do
    test "Kernel is unsafe" do
      assert Compiler.unsafe_module_name?(Kernel)
    end

    test "System is unsafe" do
      assert Compiler.unsafe_module_name?(System)
    end

    test "IO is unsafe" do
      assert Compiler.unsafe_module_name?(IO)
    end

    test "File is unsafe" do
      assert Compiler.unsafe_module_name?(File)
    end

    test "Spark.Config is safe" do
      refute Compiler.unsafe_module_name?(Spark.Config)
    end

    test "Spark.Tools.FS is safe" do
      refute Compiler.unsafe_module_name?(Spark.Tools.FS)
    end
  end

  describe "safe_modules/0" do
    test "returns expected modules" do
      modules = Compiler.safe_modules()
      assert Spark.Config in modules
      assert Spark.Dispatcher in modules
      assert Spark.Worker in modules
      assert Spark.Tools.FS in modules
      assert Spark.Tools.Shell in modules
    end
  end
end
