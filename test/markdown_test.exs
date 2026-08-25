defmodule PhoenixKitKnowledgeBase.MarkdownTest do
  @moduledoc """
  The parsing rules everything else is derived from. No database: these are
  pure functions, and they are where a subtle bug shows up as "my tag vanished"
  or "the vault thinks I linked to something I didn't".
  """
  use ExUnit.Case, async: true

  alias PhoenixKitKnowledgeBase.Markdown

  describe "split_frontmatter/1" do
    test "parses a properties block and returns the body without it" do
      {properties, body} =
        Markdown.split_frontmatter("---\ntitle: Test\nstatus: draft\n---\n\nBody text.\n")

      assert properties == %{"title" => "Test", "status" => "draft"}
      assert String.trim(body) == "Body text."
    end

    test "a note without front matter is returned untouched" do
      assert {%{}, "Just text."} = Markdown.split_frontmatter("Just text.")
    end

    test "a horizontal rule mid-note is not front matter" do
      content = "Intro\n\n---\n\nMore"
      assert {%{}, ^content} = Markdown.split_frontmatter(content)
    end

    test "invalid YAML keeps the whole note as body rather than swallowing it" do
      # The block stays visible so the author can see and fix the typo, instead
      # of the writing underneath silently disappearing from the rendered note.
      content = "---\ntitle: [unclosed\n---\n\nImportant writing.\n"
      assert {%{}, ^content} = Markdown.split_frontmatter(content)
    end

    test "valid YAML that isn't a mapping is not a properties block" do
      content = "---\n- a\n- b\n---\n\nBody\n"
      assert {%{}, ^content} = Markdown.split_frontmatter(content)
    end

    test "nil and non-binary input are tolerated" do
      assert {%{}, ""} = Markdown.split_frontmatter(nil)
    end
  end

  describe "extract_tags/2" do
    test "merges front matter tags with inline ones, downcased and sorted" do
      {properties, body} =
        Markdown.split_frontmatter("---\ntags: [Alpha, beta]\n---\n\nText #Gamma and #alpha\n")

      assert Markdown.extract_tags(properties, body) == ["alpha", "beta", "gamma"]
    end

    test "accepts front matter tags written as one string" do
      assert Markdown.extract_tags(%{"tags" => "one, two"}, "") == ["one", "two"]
    end

    test "a markdown heading is not a tag" do
      assert Markdown.extract_tags(%{}, "# Heading\n\n## Another") == []
    end

    test "nested tags keep their slash" do
      assert Markdown.extract_tags(%{}, "#project/alpha") == ["project/alpha"]
    end

    test "an all-numeric hash is not a tag" do
      assert Markdown.extract_tags(%{}, "issue #123") == []
    end

    test "tags inside code are ignored" do
      body = "Real #keeper\n\n```\n#notatag\n```\n\nAnd `#alsonot` inline."
      assert Markdown.extract_tags(%{}, body) == ["keeper"]
    end
  end

  describe "wiki_links/1" do
    test "finds plain links, aliases and heading anchors" do
      links = Markdown.wiki_links("See [[Alpha]], [[Beta|the second]] and [[Gamma#Section]].")

      assert Enum.map(links, & &1.key) == ["alpha", "beta", "gamma"]
      assert Enum.map(links, & &1.label) == ["Alpha", "the second", "Gamma#Section"]
      # The heading anchor is dropped from the resolution target.
      assert Enum.at(links, 2).target == "Gamma"
    end

    test "the same target written twice is one link" do
      assert [%{key: "alpha"}] = Markdown.wiki_links("[[Alpha]] and again [[alpha]]")
    end

    test "links inside code are not links" do
      body = "Real [[Alpha]]\n\n```\n[[Fake]]\n```\n\nand `[[AlsoFake]]`"
      assert [%{key: "alpha"}] = Markdown.wiki_links(body)
    end

    test "an empty target is not a link" do
      assert [] = Markdown.wiki_links("[[]] and [[   ]]")
    end
  end

  describe "normalize_title/1" do
    test "collapses whitespace and case so a link finds its note" do
      assert Markdown.normalize_title("  My   Note ") == "my note"
      assert Markdown.normalize_title("MY NOTE") == "my note"
    end
  end

  describe "to_html/2" do
    defp resolver(known) do
      fn link ->
        if link.key in known,
          do: {:resolved, "/notes/#{link.key}"},
          else: {:unresolved, "/notes/new?title=#{URI.encode_www_form(link.target)}"}
      end
    end

    test "resolved links render as navigable anchors" do
      html = Markdown.to_html("Go to [[Alpha]].", resolver(["alpha"]))

      assert html =~ ~s(href="/notes/alpha")
      assert html =~ ~s(data-phx-link="redirect")
      refute html =~ "text-warning"
    end

    test "unresolved links are styled so gaps are visible while reading" do
      html = Markdown.to_html("Go to [[Missing]].", resolver([]))

      assert html =~ "notes/new?title=Missing"
      assert html =~ "text-warning"
    end

    test "an alias becomes the link text" do
      html = Markdown.to_html("[[Alpha|click here]]", resolver(["alpha"]))
      assert html =~ ">click here</a>"
    end

    test "front matter is not rendered into the prose" do
      html = Markdown.to_html("---\nsecret: value\n---\n\nBody\n", resolver([]))

      refute html =~ "secret"
      assert html =~ "Body"
    end

    test "script tags in a note are sanitized away" do
      html = Markdown.to_html("Hi <script>alert('xss')</script> there", resolver([]))

      refute html =~ "<script"
      refute html =~ "alert("
    end

    test "a link to /notes/abc is not confused with /notes/abcd" do
      # The decorator matches on `href="..."` including the closing quote —
      # without it, the shorter href would prefix-match the longer one and
      # decorate the wrong anchor.
      html =
        Markdown.to_html(
          "[[ab]] and [[abc]]",
          fn link -> {:resolved, "/notes/#{link.key}"} end
        )

      assert html =~ ~s(href="/notes/ab" data-phx-link)
      assert html =~ ~s(href="/notes/abc" data-phx-link)
    end

    test "wiki-links inside fenced code stay literal" do
      html = Markdown.to_html("```\n[[Alpha]]\n```", resolver(["alpha"]))

      assert html =~ "[[Alpha]]"
      refute html =~ ~s(href="/notes/alpha")
    end
  end

  describe "excerpt/2" do
    test "strips front matter, markdown syntax and link brackets" do
      content = "---\ntitle: T\n---\n\n# Heading\n\nSome **bold** and [[Alpha|a link]]."
      excerpt = Markdown.excerpt(content, 200)

      assert excerpt =~ "Heading"
      assert excerpt =~ "a link"
      refute excerpt =~ "**"
      refute excerpt =~ "[["
      refute excerpt =~ "title: T"
    end

    test "truncates long text with an ellipsis" do
      assert Markdown.excerpt(String.duplicate("word ", 100), 20) =~ "…"
    end

    test "nil is empty" do
      assert Markdown.excerpt(nil) == ""
    end
  end
end
