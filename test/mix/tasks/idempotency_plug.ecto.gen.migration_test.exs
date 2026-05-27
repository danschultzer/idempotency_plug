defmodule Mix.Tasks.IdempotencyPlug.Ecto.Gen.MigrationTest do
  use ExUnit.Case

  test "with table name" do
    assert_raise Mix.Error, "Do not define a table name", fn ->
      Mix.Tasks.IdempotencyPlug.Ecto.Gen.Migration.run(["table"])
    end
  end

  test "with --change flag" do
    assert_raise Mix.Error, "--change flag is not allowed", fn ->
      Mix.Tasks.IdempotencyPlug.Ecto.Gen.Migration.run([
        "--change",
        "create table(:test) do\nadd :name, :string\nend"
      ])
    end
  end
end
