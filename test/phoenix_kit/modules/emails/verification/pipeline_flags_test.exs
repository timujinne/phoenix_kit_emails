defmodule PhoenixKit.Modules.Emails.Verification.PipelineFlagsTest do
  @moduledoc """
  Fake, curse and typo are flags, not verdicts (the original tool's notes say "Fake Pattern and
  Curse Words are not a verdict"): they ride along on the result and never move
  the status. The list-driven ones need an external lists directory, which is
  global state, hence a synchronous module of their own.
  """

  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Modules.Emails.Verification.Dictionaries
  alias PhoenixKit.Modules.Emails.Verification.Pipeline
  alias PhoenixKitEmails.Test.FakeResolver

  @mx {:ok, [%{host: "mx.good.example", pref: 10}]}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.write!(Path.join(dir, "Typos_Sorted.txt"), "@gmai-fixture.org\r\n")
    File.write!(Path.join(dir, "CurseWords_Sorted.txt"), "blorp\r\n")
    File.write!(Path.join(dir, "FakeAddresses_Sorted.txt"), "nobodyhome@\r\n")
    Application.put_env(:phoenix_kit_emails, :verification_lists_dir, dir)
    Dictionaries.reload()

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_emails, :verification_lists_dir)
      Dictionaries.reload()
    end)

    FakeResolver.put("good-fixture.org", mx: @mx)
    FakeResolver.put("gmai-fixture.org", mx: @mx)
    :ok
  end

  defp run(email), do: Pipeline.run(email, resolver: FakeResolver)

  test "a typo domain is flagged and keeps the verdict it would have had" do
    typo = run("john@gmai-fixture.org")
    other = run("john@good-fixture.org")

    assert typo.typo
    refute other.typo
    assert {typo.status, typo.reason, typo.level} == {other.status, other.reason, other.level}
  end

  test "a typo domain that does not resolve is still flagged" do
    FakeResolver.put("gmai-fixture.org", mx: {:error, :nxdomain})
    result = run("john@gmai-fixture.org")

    assert {result.status, result.reason} == {"invalid", "no_mx"}
    assert result.typo
  end

  test "curse and list-based fake flags are set and change no status" do
    curse = run("blorp@good-fixture.org")
    fake = run("nobodyhome@good-fixture.org")
    plain = run("john@good-fixture.org")

    assert %{curse: true, fake: false} = curse
    assert %{curse: false, fake: true} = fake
    assert %{curse: false, fake: false, typo: false} = plain
    assert Enum.uniq([curse.status, fake.status, plain.status]) == ["not_sure"]
  end

  test "flags are computed even when a later step ends the run" do
    bad_tld = run("asdfgh@good-fixture.invalidtld")
    assert {bad_tld.status, bad_tld.reason} == {"invalid", "bad_tld"}
    assert bad_tld.fake

    disposable = run("blorp@mailinator.com")
    assert {disposable.status, disposable.reason} == {"temp", "disposable"}
    assert disposable.curse
  end

  test "the log records the marks step with the three flags" do
    result = run("blorp@gmai-fixture.org")

    assert %{"outcome" => "ok", "fake" => false, "curse" => true, "typo" => true} =
             Enum.find(result.log, &(&1["step"] == "marks"))
  end
end
