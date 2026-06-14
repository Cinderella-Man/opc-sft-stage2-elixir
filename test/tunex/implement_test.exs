defmodule Tunex.ImplementTest do
  use ExUnit.Case, async: true

  alias Tunex.Implement.{Naming, Output, Seed}

  describe "Output.parse/2 — new mode" do
    @pattern_emit """
    ===RULE===
    defmodule Credence.Pattern.NoFoo do
    end
    ===CHECK_TEST===
    defmodule X do
    end
    ===FIX_TEST===
    defmodule Y do
    end
    ===EQUIVALENCE_TEST===
    defmodule Z do
    end
    ===END===
    """

    test "pattern requires RULE+CHECK+FIX+EQUIVALENCE" do
      assert {:ok, %{rule: rule, tests: tests}} =
               Output.parse(@pattern_emit, mode: :new, phase: :pattern, assumptions?: false)

      assert rule =~ "NoFoo"
      assert Map.has_key?(tests, "EQUIVALENCE_TEST")
    end

    test "strips an outer ```elixir fence off blocks so the file compiles (docs/10 Fix 2)" do
      emit = """
      ===RULE===
      ```elixir
      defmodule Credence.Pattern.NoFoo do
      end
      ```
      ===CHECK_TEST===
      defmodule X do
      end
      ===FIX_TEST===
      defmodule Y do
      end
      ===EQUIVALENCE_TEST===
      defmodule Z do
      end
      ===END===
      """

      assert {:ok, %{rule: rule}} = Output.parse(emit, mode: :new, phase: :pattern, assumptions?: false)
      refute rule =~ "```"
      assert {:ok, _} = Code.string_to_quoted(rule)
    end

    test "pattern missing EQUIVALENCE_TEST is rejected" do
      emit = "===RULE===\nx\n===CHECK_TEST===\nx\n===FIX_TEST===\nx\n===END==="
      assert {:error, :pattern_missing_equivalence_test} = Output.parse(emit, mode: :new, phase: :pattern, assumptions?: false)
    end

    test "syntax WITH an equivalence test is rejected" do
      assert {:error, :non_pattern_has_equivalence_test} =
               Output.parse(@pattern_emit, mode: :new, phase: :syntax, assumptions?: false)
    end

    test "switch-gated pattern must carry PROPERTY_TEST" do
      assert {:error, :switch_gated_missing_property_test} =
               Output.parse(@pattern_emit, mode: :new, phase: :pattern, assumptions?: true)
    end

    test "no-promise pattern with a stray PROPERTY_TEST is rejected" do
      emit = @pattern_emit |> String.replace("===END===", "===PROPERTY_TEST===\nx\n===END===")
      assert {:error, :no_promise_has_property_test} = Output.parse(emit, mode: :new, phase: :pattern, assumptions?: false)
    end
  end

  describe "Output.parse/2 — bugfix mode" do
    test "accepts path-keyed tests within the glob" do
      emit = """
      ===RULE===
      defmodule Credence.Pattern.NoFoo do
      end
      ===TEST:test/pattern/no_foo_check_test.exs===
      x
      ===END===
      """

      assert {:ok, %{rule: _, tests: tests}} =
               Output.parse(emit, mode: :bugfix, test_glob: ["test/pattern/no_foo_check_test.exs"])

      assert Map.has_key?(tests, "test/pattern/no_foo_check_test.exs")
    end

    test "rejects a test path outside the glob (no new/renamed files)" do
      emit = "===RULE===\nx\n===TEST:test/pattern/sneaky_test.exs===\nx\n===END==="
      assert {:error, {:test_path_out_of_glob, "test/pattern/sneaky_test.exs"}} =
               Output.parse(emit, mode: :bugfix, test_glob: ["test/pattern/no_foo_check_test.exs"])
    end
  end

  describe "Seed.build/1" do
    test "new pattern seed carries scaffold + AST + invariants + contract" do
      ctx = %{
        mode: :new,
        phase: :pattern,
        spec: %{before: "defmodule B do\nend", after: "defmodule A do\nend", rationale: "x", assumptions: []},
        scaffold_files: %{"lib/pattern/no_foo.ex" => "defmodule Credence.Pattern.NoFoo do\nend"},
        ast_before: "{:defmodule, ...}",
        ast_after: "{:defmodule, ...}",
        minimal_set: [],
        repair?: false
      }

      user = Seed.build(ctx)
      assert user =~ "Generated scaffold"
      assert user =~ "lib/pattern/no_foo.ex"
      assert user =~ "Type-change ban"
      assert user =~ "EQUIVALENCE_TEST"
      assert user =~ "AST dumps"
      # the before/after are a fixable sketch, not gospel (docs/10)
      assert user =~ "ONE-SHOT proposal"
    end

    test "pi driver: same context, but an AGENT task instead of the marker contract (docs/10)" do
      ctx = %{
        mode: :new,
        phase: :pattern,
        spec: %{before: "defmodule B do\nend", after: "defmodule A do\nend", rationale: "x", assumptions: []},
        scaffold: %{phase: :pattern, snake: "no_foo"},
        scaffold_files: %{"lib/pattern/no_foo.ex" => "defmodule Credence.Pattern.NoFoo do\nend"},
        ast_before: "a",
        ast_after: "b",
        minimal_set: [],
        repair?: false
      }

      user = Seed.build(ctx, driver: :pi)
      # rich context is still injected
      assert user =~ "Generated scaffold"
      assert user =~ "Type-change ban"
      assert user =~ "AST dumps"
      # ...but the closing is the agent task (loop on mix test), not the markers
      assert user =~ "AGENTIC"
      assert user =~ "mix test test/pattern/no_foo*_test.exs"
      refute user =~ "===RULE==="
    end

    test "cc driver: an agent give-up is tagged {:cc, reason} so the router routes it transient" do
      ctx = %{
        mode: :new,
        phase: :pattern,
        spec: %{before: "defmodule B do\nend", after: "defmodule A do\nend", rationale: "x", assumptions: []},
        scaffold: %{phase: :pattern, snake: "no_foo"},
        scaffold_files: %{"lib/pattern/no_foo.ex" => "defmodule Credence.Pattern.NoFoo do\nend"},
        ast_before: "a",
        ast_after: "b",
        minimal_set: [],
        repair?: false,
        clone: "/nonexistent",
        row: 7
      }

      # The :cc driver accepts the same injectable agent fn as :pi; a give-up
      # must be wrapped under the :cc tag (NOT :pi) so `rulegen_error_class/1`
      # classifies a "timeout" as transient rather than a dead-end.
      agent = fn _prompt, _opts -> {:gave_up, "timeout"} end

      assert {:gave_up, {:cc, "timeout"}} =
               Tunex.Implement.run(ctx, driver: :cc, pi: agent)
    end

    test "semantic seed carries the real diagnostic, not an AST dump" do
      ctx = %{
        mode: :new,
        phase: :semantic,
        spec: %{before: "x", after: "y", rationale: "r", assumptions: []},
        scaffold_files: %{},
        real_diagnostic: "%{message: \"undefined\", position: {3, 5}, severity: :error}",
        minimal_set: [],
        repair?: false
      }

      user = Seed.build(ctx)
      assert user =~ "REAL captured diagnostic"
      assert user =~ "position: {3, 5}"
      refute user =~ "AST dumps"
    end

    test "repair sub-mode instructs mark_equivalence_repair" do
      ctx = %{
        mode: :new,
        phase: :pattern,
        spec: %{before: "x", after: "y", rationale: "r", assumptions: []},
        scaffold_files: %{},
        ast_before: "a",
        ast_after: "b",
        minimal_set: [],
        repair?: true,
        repair_evidence: "FunctionClauseError 9/9"
      }

      user = Seed.build(ctx)
      assert user =~ "mark_equivalence_repair"
      assert user =~ "FunctionClauseError 9/9"
    end

    test "syntax seed carries parser-driven fix guidance + the confirm_fix convention" do
      ctx = %{
        mode: :new,
        phase: :syntax,
        spec: %{before: "x", after: "y", rationale: "r", assumptions: []},
        scaffold_files: %{},
        minimal_set: [],
        repair?: false
      }

      user = Seed.build(ctx)
      # parser-driven fault location, not line/text heuristics (docs/12 §B)
      assert user =~ "Syntax-fix guidance"
      assert user =~ "Code.string_to_quoted"
      # the fix-test convention is the newline-insensitive helper, for every phase
      assert user =~ "confirm_fix"
      refute user =~ "compare the WHOLE output with `==`"
    end

    test "pattern seed omits the syntax-only fix guidance" do
      ctx = %{
        mode: :new,
        phase: :pattern,
        spec: %{before: "x", after: "y", rationale: "r", assumptions: []},
        scaffold_files: %{},
        ast_before: "a",
        ast_after: "b",
        minimal_set: [],
        repair?: false
      }

      refute Seed.build(ctx) =~ "Syntax-fix guidance"
    end
  end

  describe "Naming.resolve_and_scaffold/3 (real clone — integration)" do
    @describetag :integration

    test "name collisions progress _2/_3 with snake matching the on-disk file (docs/10)" do
      clone = Tunex.Config.credence_clone()
      base = "no_tunex_collision_probe"

      on_exit(fn ->
        for suffix <- ["", "2", "3"] do
          File.rm(Path.join(clone, "lib/pattern/#{base}#{suffix}.ex"))
          for k <- ~w(check fix equivalence),
              do: File.rm(Path.join(clone, "test/pattern/#{base}#{suffix}_#{k}_test.exs"))
        end
      end)

      {:ok, s1} = Naming.resolve_and_scaffold(base, :pattern, clone)
      {:ok, s2} = Naming.resolve_and_scaffold(base, :pattern, clone)
      {:ok, s3} = Naming.resolve_and_scaffold(base, :pattern, clone)

      assert s1.snake == base
      assert s2.snake == "#{base}2"
      assert s3.snake == "#{base}3"

      # snake must equal the actual lib file's basename (the canonicalization fix).
      for s <- [s1, s2, s3] do
        libfile = Enum.find(s.paths, &String.starts_with?(&1, "lib/"))
        assert libfile == "lib/pattern/#{s.snake}.ex"
      end
    end

    test "generates honest-red stubs that fail their own focused test, then clean up" do
      clone = Tunex.Config.credence_clone()
      name = "no_tunex_scaffold_probe"

      assert {:ok, sc} = Naming.resolve_and_scaffold(name, :pattern, clone)

      # SURGICAL cleanup — delete ONLY the generated scaffold files. NEVER
      # `git checkout . && git clean -fd` the clone: that wipes any uncommitted
      # clone work (it once reverted the whole Phase-1 Credence PR mid-build).
      on_exit(fn ->
        Enum.each(sc.paths, fn rel -> File.rm(Path.join(clone, rel)) end)
      end)
      assert sc.module == :"Elixir.Credence.Pattern.NoTunexScaffoldProbe"
      # Pattern → 4 files incl. the equivalence test.
      assert Enum.any?(sc.paths, &String.ends_with?(&1, "_equivalence_test.exs"))
      assert map_size(sc.files) == length(sc.paths)

      # Honest-red: the generated stub's own tests FAIL (rule must fire, etc.).
      {_out, code} =
        System.cmd("mix", ["test" | Enum.filter(sc.paths, &String.starts_with?(&1, "test/"))],
          cd: clone,
          stderr_to_stdout: true,
          env: [{"MIX_ENV", "test"}]
        )

      assert code != 0, "expected the generated stub tests to be RED"
    end
  end
end
