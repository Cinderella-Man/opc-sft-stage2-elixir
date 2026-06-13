defmodule Tunex.Evolve.CorpusTest do
  use ExUnit.Case, async: true
  alias Tunex.Evolve.Corpus

  describe "findings/1" do
    test "keeps finding lines, drops blanks + comments" do
      body = """
      # Accepted corpus findings — snapshot.
      #
      lib/ecto/query.ex:42  no_case_true_false

      lib/plug/conn.ex:7  use_map_join
      """

      assert Corpus.findings(body) == [
               "lib/ecto/query.ex:42  no_case_true_false",
               "lib/plug/conn.ex:7  use_map_join"
             ]
    end
  end

  describe "diff/2" do
    test "classifies added lines as new (over-fire) and removed as gone (narrowing)" do
      before = ~w(a b c)
      live = ~w(b c d)

      assert Corpus.diff(before, live) == %{new: ["d"], gone: ["a"]}
    end

    test "identical sets yield no drift" do
      assert Corpus.diff(~w(a b), ~w(a b)) == %{new: [], gone: []}
    end
  end
end
