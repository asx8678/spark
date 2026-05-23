defmodule Spark.ModelCatalogTest do
  use ExUnit.Case, async: true

  describe "list_providers/0" do
    test "returns list of provider keys" do
      providers = Spark.ModelCatalog.list_providers()
      assert "deepseek" in providers
      assert "wafer" in providers
    end
  end

  describe "models_for_provider/1" do
    test "returns models for deepseek" do
      models = Spark.ModelCatalog.models_for_provider("deepseek")
      assert length(models) >= 2
      ids = Enum.map(models, & &1.id)
      assert "deepseek-v4-pro" in ids
      assert "deepseek-v4-flash" in ids
    end

    test "returns models for wafer" do
      models = Spark.ModelCatalog.models_for_provider("wafer")
      assert length(models) >= 1
      ids = Enum.map(models, & &1.id)
      assert "glm-5.1" in ids
    end

    test "returns empty list for unknown provider" do
      assert Spark.ModelCatalog.models_for_provider("unknown") == []
    end
  end

  describe "find_model/2" do
    test "finds existing model" do
      model = Spark.ModelCatalog.find_model("deepseek", "deepseek-v4-pro")
      assert model != nil
      assert model.id == "deepseek-v4-pro"
      assert model.name == "DeepSeek V4 Pro"
    end

    test "returns nil for unknown model" do
      assert Spark.ModelCatalog.find_model("deepseek", "nonexistent") == nil
    end

    test "returns nil for unknown provider" do
      assert Spark.ModelCatalog.find_model("unknown", "deepseek-v4-pro") == nil
    end
  end

  describe "default_base_url/1" do
    test "returns deepseek base url" do
      assert Spark.ModelCatalog.default_base_url("deepseek") == "https://api.deepseek.com"
    end

    test "returns wafer base url" do
      assert Spark.ModelCatalog.default_base_url("wafer") == "https://pass.wafer.ai/v1"
    end

    test "returns fallback for unknown provider" do
      assert Spark.ModelCatalog.default_base_url("unknown") == "https://api.deepseek.com"
    end
  end
end
