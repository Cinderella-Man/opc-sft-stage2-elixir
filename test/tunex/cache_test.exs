defmodule Tunex.CacheTest do
  use ExUnit.Case, async: true
  alias Tunex.Cache

  setup do
    tmp = Path.join(System.tmp_dir!(), "tunex_cache_#{System.unique_integer([:positive])}.jsonl")
    {:ok, pid} = Cache.start_link(path: tmp, name: nil)
    on_exit(fn -> File.rm(tmp) end)
    %{cache: pid, path: tmp}
  end

  test "put then get round-trips an :ok record", %{cache: c} do
    key = Cache.key("sys", "user", "model")
    :ok = Cache.put(key, %{verdict: :ok, instruction: "i", test: "t", reference: "r"}, c)

    rec = Cache.get(key, c)
    assert rec.verdict == :ok
    assert rec.reason == nil
    assert rec.instruction == "i"
    assert rec.reference == "r"
    refute Cache.blacklisted?(rec)
  end

  test "blacklist record (payload-less) is recognized", %{cache: c} do
    key = Cache.key("sys", "user2", "model")
    :ok = Cache.put(key, %{verdict: :blacklist, reason: :untranslatable}, c)

    rec = Cache.get(key, c)
    assert Cache.blacklisted?(rec)
    assert rec.reason == :untranslatable
    assert rec.reference == nil
  end

  test "miss returns nil and blacklisted?/1 handles nil", %{cache: c} do
    assert Cache.get("nope", c) == nil
    refute Cache.blacklisted?(nil)
  end

  test "key changes when any component changes" do
    a = Cache.key("sys", "user", "model")
    assert a == Cache.key("sys", "user", "model")
    refute a == Cache.key("sys2", "user", "model")
    refute a == Cache.key("sys", "user2", "model")
    refute a == Cache.key("sys", "user", "model2")
  end

  test "records survive a reload (persisted to jsonl)", %{path: path} do
    {:ok, c1} = Cache.start_link(path: path, name: nil)
    key = Cache.key("s", "u", "m")
    :ok = Cache.put(key, %{verdict: :ok, instruction: "i", test: "t", reference: "r"}, c1)
    GenServer.stop(c1)

    {:ok, c2} = Cache.start_link(path: path, name: nil)
    rec = Cache.get(key, c2)
    assert rec.verdict == :ok
    assert rec.instruction == "i"
    GenServer.stop(c2)
  end
end
