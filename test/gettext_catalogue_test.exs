defmodule PhoenixKitKnowledgeBase.GettextCatalogueTest do
  @moduledoc """
  The notes panel ships translated: Russian and Estonian, for this module's
  own strings (`default`) and for the Leaf editor inside the panel (`leaf`).
  A message added without its translations would show English in the middle
  of a Russian page — this fails first.
  """
  use ExUnit.Case, async: true

  @locales ~w(ru et)
  @domains ~w(default leaf)

  defp entries(path) do
    path
    |> File.read!()
    |> String.split(~r/\n\n+/)
    |> Enum.flat_map(fn block ->
      case Regex.run(~r/^msgid "((?:[^"\\]|\\.)*)"$/m, block) do
        [_, ""] -> []
        [_, id] -> [{id, Regex.scan(~r/^msgstr(?:\[\d+\])? "((?:[^"\\]|\\.)*)"$/m, block)}]
        nil -> []
      end
    end)
  end

  for domain <- @domains do
    test "the #{domain} template has messages" do
      assert entries("priv/gettext/#{unquote(domain)}.pot") != []
    end

    for locale <- @locales do
      test "#{locale}/#{domain}.po translates every message of #{domain}.pot" do
        template = "priv/gettext/#{unquote(domain)}.pot" |> entries() |> Enum.map(&elem(&1, 0))
        translated = entries("priv/gettext/#{unquote(locale)}/LC_MESSAGES/#{unquote(domain)}.po")

        assert Enum.sort(Enum.map(translated, &elem(&1, 0))) == Enum.sort(template),
               "#{unquote(locale)}/#{unquote(domain)}.po is out of step with the template — run mix gettext.merge priv/gettext"

        empty =
          for {id, strs} <- translated, Enum.any?(strs, fn [_, str] -> str == "" end), do: id

        assert empty == [], "untranslated in #{unquote(locale)}: #{inspect(empty)}"
      end
    end
  end

  test "Leaf's catalogue is the one the Leaf in the lock ships, or newer" do
    shipped = "priv/gettext/leaf.pot" |> entries() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    upstream =
      Path.join(Application.app_dir(:leaf), "priv/gettext/leaf.pot")
      |> entries()
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    assert MapSet.subset?(upstream, shipped),
           "Leaf has strings this module does not translate: " <>
             inspect(MapSet.difference(upstream, shipped) |> Enum.to_list())
  end
end
