Code.require_file("../test_helper.exs", __DIR__)

defmodule Module.TypesTest do
  use ExUnit.Case, async: true
  import Bitwise, warn: false
  alias Module.Types

  defmacrop quoted_head(patterns, guards \\ [true]) do
    quote do
      {patterns, guards} = unquote(Macro.escape(expand_head(patterns, guards)))

      Types.of_head(
        patterns,
        guards,
        def_expr(),
        new_context()
      )
      |> maybe_error()
    end
  end

  defp expand_head(patterns, guards) do
    {_, vars} =
      Macro.prewalk(patterns, [], fn
        {:_, _, context} = var, vars when is_atom(context) ->
          {var, vars}

        {name, _, context} = var, vars when is_atom(name) and is_atom(context) ->
          {var, [var | vars]}

        other, vars ->
          {other, vars}
      end)

    fun =
      quote do
        fn unquote(patterns) when unquote(guards) -> unquote(vars) end
      end

    {ast, _env} = :elixir_expand.expand(fun, __ENV__)
    {:fn, _, [{:->, _, [[{:when, _, [patterns, guards]}], _]}]} = ast
    {patterns, guards}
  end

  defp new_context() do
    Types.context("types_test.ex", TypesTest, {:test, 0})
  end

  defp def_expr() do
    {:def, [], {:test, [], []}}
  end

  defp maybe_error({:ok, types, context}) when is_list(types) do
    {:ok, Types.lift_types(types, context)}
  end

  defp maybe_error({:error, {Types, reason, location}}) do
    {:error, {reason, location}}
  end

  describe "of_head/4" do
    test "various" do
      assert quoted_head([true]) == {:ok, [{:atom, true}]}
      assert quoted_head([foo]) == {:ok, [{:var, 0}]}
    end

    test "variable" do
      assert quoted_head([a]) == {:ok, [{:var, 0}]}
      assert quoted_head([a, b]) == {:ok, [{:var, 0}, {:var, 1}]}
      assert quoted_head([a, a]) == {:ok, [{:var, 0}, {:var, 0}]}

      assert {:ok, [{:var, 0}, {:var, 0}], _} =
               Types.of_head(
                 [{:a, [version: 0], :foo}, {:a, [version: 0], :foo}],
                 [],
                 def_expr(),
                 new_context()
               )

      assert {:ok, [{:var, 0}, {:var, 1}], _} =
               Types.of_head(
                 [{:a, [version: 0], :foo}, {:a, [version: 1], :foo}],
                 [],
                 def_expr(),
                 new_context()
               )
    end

    test "assignment" do
      assert quoted_head([x = y, x = y]) == {:ok, [{:var, 0}, {:var, 0}]}
      assert quoted_head([x = y, y = x]) == {:ok, [{:var, 0}, {:var, 0}]}

      assert quoted_head([x = :foo, x = y, y = z]) ==
               {:ok, [{:atom, :foo}, {:atom, :foo}, {:atom, :foo}]}

      assert quoted_head([x = y, y = :foo, y = z]) ==
               {:ok, [{:atom, :foo}, {:atom, :foo}, {:atom, :foo}]}

      assert quoted_head([x = y, y = z, z = :foo]) ==
               {:ok, [{:atom, :foo}, {:atom, :foo}, {:atom, :foo}]}

      assert {:error, {{:unable_unify, {:tuple, [var: 1]}, {:var, 0}, _, _}, _}} =
               quoted_head([{x} = y, {y} = x])
    end

    test "guards" do
      assert quoted_head([x], [is_binary(x)]) == {:ok, [:binary]}

      assert quoted_head([x, y], [is_binary(x) and is_atom(y)]) ==
               {:ok, [:binary, :atom]}

      assert quoted_head([x], [is_binary(x) or is_atom(x)]) ==
               {:ok, [{:union, [:binary, :atom]}]}

      assert quoted_head([x, x], [is_integer(x)]) == {:ok, [:integer, :integer]}

      assert quoted_head([x = 123], [is_integer(x)]) == {:ok, [:integer]}

      assert quoted_head([x], [is_boolean(x) or is_atom(x)]) ==
               {:ok, [:atom]}

      assert quoted_head([x], [is_atom(x) or is_boolean(x)]) ==
               {:ok, [:atom]}

      assert quoted_head([x], [is_tuple(x) or is_atom(x)]) ==
               {:ok, [{:union, [:tuple, :atom]}]}

      assert quoted_head([x], [is_boolean(x) and is_atom(x)]) ==
               {:ok, [:boolean]}

      assert quoted_head([x], [is_atom(x) and is_boolean(x)]) ==
               {:ok, [:boolean]}

      assert quoted_head([x], [is_atom(x) > :foo]) == {:ok, [var: 0]}

      assert quoted_head([x, x = y, y = z], [is_atom(x)]) ==
               {:ok, [:atom, :atom, :atom]}

      assert quoted_head([x = y, y, y = z], [is_atom(y)]) ==
               {:ok, [:atom, :atom, :atom]}

      assert quoted_head([x = y, y = z, z], [is_atom(z)]) ==
               {:ok, [:atom, :atom, :atom]}

      assert {:error, {{:unable_unify, :binary, :integer, _, _}, _}} =
               quoted_head([x], [is_binary(x) and is_integer(x)])

      assert {:error, {{:unable_unify, :tuple, :atom, _, _}, _}} =
               quoted_head([x], [is_tuple(x) and is_atom(x)])

      assert {:error, {{:unable_unify, :boolean, :tuple, _, _}, _}} =
               quoted_head([x], [is_tuple(is_atom(x))])
    end

    test "erlang-only guards" do
      assert quoted_head([x], [:erlang.size(x)]) ==
               {:ok, [{:union, [:binary, :tuple]}]}
    end

    test "failing guard functions" do
      assert quoted_head([x], [length([])]) == {:ok, [{:var, 0}]}

      assert {:error, {{:unable_unify, {:atom, :foo}, {:list, :dynamic}, _, _}, _}} =
               quoted_head([x], [length(:foo)])

      assert {:error, {{:unable_unify, :boolean, {:list, :dynamic}, _, _}, _}} =
               quoted_head([x], [length(is_tuple(x))])

      assert {:error, {{:unable_unify, :boolean, :tuple, _, _}, _}} =
               quoted_head([x], [elem(is_tuple(x), 0)])

      assert {:error, {{:unable_unify, :boolean, :number, _, _}, _}} =
               quoted_head([x], [elem({}, is_tuple(x))])

      assert quoted_head([x], [elem({}, 1)]) == {:ok, [var: 0]}

      assert quoted_head([x], [elem(x, 1) == :foo]) == {:ok, [:tuple]}

      assert quoted_head([x], [is_tuple(x) and elem(x, 1)]) == {:ok, [:tuple]}

      assert quoted_head([x], [length(x) == 0 or elem(x, 1)]) == {:ok, [{:list, :dynamic}]}

      assert quoted_head([x], [
               (is_list(x) and length(x) == 0) or (is_tuple(x) and elem(x, 1))
             ]) ==
               {:ok, [{:union, [{:list, :dynamic}, :tuple]}]}

      assert quoted_head([x], [
               (length(x) == 0 and is_list(x)) or (elem(x, 1) and is_tuple(x))
             ]) == {:ok, [{:list, :dynamic}]}

      assert quoted_head([x, y], [elem(x, 1) and is_atom(y)]) == {:ok, [:tuple, :atom]}

      assert quoted_head([x], [elem(x, 1) or is_atom(x)]) == {:ok, [:tuple]}

      assert quoted_head([x, y], [elem(x, 1) or is_atom(y)]) == {:ok, [:tuple, {:var, 0}]}

      assert {:error, {{:unable_unify, :tuple, :atom, _, _}, _}} =
               quoted_head([x], [elem(x, 1) and is_atom(x)])
    end

    test "map" do
      assert quoted_head([%{true: false} = foo, %{} = foo]) ==
               {:ok,
                [
                  {:map, [{{:atom, true}, {:atom, false}}]},
                  {:map, [{{:atom, true}, {:atom, false}}]}
                ]}

      assert quoted_head([%{true: bool}], [is_boolean(bool)]) ==
               {:ok,
                [
                  {:map, [{{:atom, true}, :boolean}]}
                ]}

      assert quoted_head([%{true: true} = foo, %{false: false} = foo]) ==
               {:ok,
                [
                  {:map, [{{:atom, false}, {:atom, false}}, {{:atom, true}, {:atom, true}}]},
                  {:map, [{{:atom, false}, {:atom, false}}, {{:atom, true}, {:atom, true}}]}
                ]}

      assert {:error, {{:unable_unify, {:atom, true}, {:atom, false}, _, _}, _}} =
               quoted_head([%{true: false} = foo, %{true: true} = foo])
    end

    test "struct var guard" do
      assert quoted_head([%var{}], [is_atom(var)]) ==
               {:ok, [{:map, [{{:atom, :__struct__}, :atom}]}]}

      assert {:error, {{:unable_unify, :atom, :integer, _, _}, _}} =
               quoted_head([%var{}], [is_integer(var)])
    end
  end

  test "format_type/1" do
    assert Types.format_type(:binary) == "binary()"
    assert Types.format_type({:atom, true}) == "true"
    assert Types.format_type({:atom, :atom}) == ":atom"
    assert Types.format_type({:list, :binary}) == "[binary()]"
    assert Types.format_type({:tuple, []}) == "{}"
    assert Types.format_type({:tuple, [:integer]}) == "{integer()}"
    assert Types.format_type({:map, []}) == "%{}"
    assert Types.format_type({:map, [{:integer, :atom}]}) == "%{integer() => atom()}"
    assert Types.format_type({:map, [{:__struct__, Struct}]}) == "%Struct{}"

    assert Types.format_type({:map, [{:__struct__, Struct}, {:integer, :atom}]}) ==
             "%Struct{integer() => atom()}"
  end

  test "expr_to_string/1" do
    assert Types.expr_to_string({1, 2}) == "{1, 2}"
    assert Types.expr_to_string(quote(do: Foo.bar(arg))) == "Foo.bar(arg)"
    assert Types.expr_to_string(quote(do: :erlang.band(a, b))) == "Bitwise.band(a, b)"
    assert Types.expr_to_string(quote(do: :erlang.orelse(a, b))) == "a or b"
    assert Types.expr_to_string(quote(do: :erlang."=:="(a, b))) == "a === b"
    assert Types.expr_to_string(quote(do: :erlang.list_to_atom(a))) == "List.to_atom(a)"
    assert Types.expr_to_string(quote(do: :maps.remove(a, b))) == "Map.delete(b, a)"
    assert Types.expr_to_string(quote(do: :erlang.element(1, a))) == "elem(a, 0)"
    assert Types.expr_to_string(quote(do: :erlang.element(:erlang.+(a, 1), b))) == "elem(b, a)"
  end
end
