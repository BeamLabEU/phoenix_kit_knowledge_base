defmodule PhoenixKitKnowledgeBase.Markdown do
  @moduledoc """
  Everything this module knows how to read out of a note's markdown: YAML front
  matter, tags, `[[wiki-links]]`, and the rendered HTML.

  The markdown is the single source of truth. `title_key`, `frontmatter`, `tags`
  and the whole link index are derived from it on save, which is what keeps
  notes portable — the database holds nothing you could not recover by
  re-reading the text.

  ## Code is not scanned

  Tags and wiki-links are only read from *outside* code, so a `[[Foo]]` inside a
  fenced block or a backtick span stays literal instead of quietly becoming a
  link and a phantom entry in the vault's unresolved list. Fenced blocks
  (```` ``` ````, `~~~`) and inline spans are handled; four-space indented code
  blocks are not, because telling one apart from a wrapped list item needs a
  real block parser.
  """

  alias PhoenixKit.Utils.HtmlSanitizer

  # `---` … `---` at the very top of the file, Obsidian's "properties" block.
  @frontmatter_regex ~r{\A---\r?\n(?<yaml>.*?)\r?\n---[ \t]*(?:\r?\n|\z)(?<body>.*)\z}s

  # `[[Target]]`, `[[Target|Alias]]`, `[[Target#Heading|Alias]]`. Nested
  # brackets are excluded, which is also why note titles reject `[` and `]`.
  @wiki_link_regex ~r{\[\[([^\[\]\n]+)\]\]}

  # An inline `#tag`: preceded by start-of-line or whitespace, and containing at
  # least one letter or underscore so that `#1` and a `#fff` colour-ish token
  # made only of digits don't become tags. `/` is allowed for Obsidian's nested
  # tags (`#project/alpha`). A markdown heading (`# Title`) has a space after
  # the hash, so it can never match.
  @inline_tag_regex ~r/(?:^|\s)\#([\p{L}\p{N}_\/-]*[\p{L}_][\p{L}\p{N}_\/-]*)/u

  # Fenced blocks and inline spans, captured so `Regex.split/3` with
  # `include_captures: true` yields alternating prose/code segments.
  @code_segment_regex ~r{(```.*?```|~~~.*?~~~|`[^`\n]*`)}s

  # Tailwind utilities, not a stylesheet: this module ships no CSS, and
  # `css_sources/0` puts `lib/` in the host's Tailwind scan path, so the classes
  # in this literal are generated like any other. Dotted underline + muted
  # colour is how Obsidian marks a link to a note that doesn't exist yet.
  @unresolved_link_class "text-warning underline decoration-dotted underline-offset-2"

  # Past these, a `[[…]]` is not a link and a `#…` is not a tag. Each is stored
  # in an indexed column, and a B-tree entry tops out near 2.7 KB — an insert
  # past it raises. No note's path is anywhere near 1,000 bytes; a tag is a
  # filter chip. What is longer is prose that happens to have brackets around
  # it (a pasted shell `[[ … ]]`, say), and stays prose.
  @max_link_target_bytes 1000
  @max_tag_length 255

  @typedoc """
  One parsed `[[wiki-link]]`.

    * `:key`    — normalised target, what resolution matches on
    * `:target` — the target as written (without any `#heading` part)
    * `:label`  — what to display: the alias after `|`, or the target
  """
  @type wiki_link :: %{key: String.t(), target: String.t(), label: String.t()}

  @doc """
  Splits YAML front matter off the top of a note.

  Returns `{properties, body}`. A note with no front matter returns `{%{}, note}`
  unchanged — and so does one whose front matter is invalid YAML, deliberately:
  a typo in a property block must not swallow the writing underneath it. The
  broken block stays visible in the body, where the author can see and fix it.
  """
  @spec split_frontmatter(String.t() | nil) :: {map(), String.t()}
  def split_frontmatter(nil), do: {%{}, ""}

  def split_frontmatter(content) when is_binary(content) do
    case Regex.named_captures(@frontmatter_regex, content) do
      %{"yaml" => yaml, "body" => body} ->
        case YamlElixir.read_from_string(yaml) do
          {:ok, %{} = properties} -> {jsonable(properties), body}
          # Valid YAML that isn't a mapping (a bare list, say) is not a
          # properties block; and invalid YAML is not one either.
          _ -> {%{}, content}
        end

      nil ->
        {%{}, content}
    end
  rescue
    # YamlElixir raises on some malformed input rather than returning an error.
    _ -> {%{}, content}
  end

  def split_frontmatter(_), do: {%{}, ""}

  @doc """
  All tags for a note: front matter `tags:` merged with inline `#tags` in the
  body, downcased, de-duplicated and sorted.

  Front matter accepts either a list (`tags: [a, b]`) or a single string
  (`tags: a, b`), which are the two spellings Obsidian itself accepts.

  Tags are downcased so `#Project` and `#project` are one tag — they are a
  filtering key here, not a display string.
  """
  @spec extract_tags(map(), String.t()) :: [String.t()]
  def extract_tags(frontmatter, body) when is_map(frontmatter) and is_binary(body) do
    (frontmatter_tags(frontmatter) ++ inline_tags(body))
    |> Enum.map(&normalize_tag/1)
    |> Enum.reject(&(&1 in [nil, ""] or String.length(&1) > @max_tag_length))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Every distinct `[[wiki-link]]` in a body, in order of first appearance.

  De-duplicated by `:key`, because writing `[[Foo]]` five times in one note is
  one link, not five — the same thing the `(source_note_uuid, target_key)`
  unique index enforces in the database.
  """
  @spec wiki_links(String.t() | nil) :: [wiki_link()]
  def wiki_links(nil), do: []

  def wiki_links(body) when is_binary(body) do
    body
    |> prose_segments()
    |> Enum.flat_map(&Regex.scan(@wiki_link_regex, &1, capture: :all_but_first))
    |> Enum.map(fn [inner] -> parse_wiki_link(inner) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.key)
  end

  @doc """
  Parses the inside of one `[[...]]` into a `t:wiki_link/0`, or `nil` if there
  is no target left after trimming.

  `[[Target#Heading|Alias]]` keeps `Alias` as the label and resolves against
  `Target` — the heading anchor is dropped, since this module has no
  heading-level addressing yet.
  """
  @spec parse_wiki_link(String.t()) :: wiki_link() | nil
  def parse_wiki_link(inner) when is_binary(inner) do
    {target_part, label} =
      case String.split(inner, "|", parts: 2) do
        [target, alias_text] -> {target, String.trim(alias_text)}
        [target] -> {target, nil}
      end

    target =
      target_part
      |> String.split("#", parts: 2)
      |> hd()
      |> String.trim()

    case normalize_title(target) do
      nil ->
        nil

      "" ->
        nil

      _too_long when byte_size(target) > @max_link_target_bytes ->
        nil

      key ->
        label = if label in [nil, ""], do: String.trim(target_part), else: label
        %{key: key, target: target, label: label}
    end
  end

  @doc """
  The canonical form of a note title — downcased with runs of whitespace
  collapsed.

  This is what the per-vault unique index constrains and what `[[wiki-links]]`
  match on, so "My  Note", "my note" and " My Note " are all the same note.
  """
  @spec normalize_title(String.t() | nil) :: String.t() | nil
  def normalize_title(nil), do: nil

  def normalize_title(title) when is_binary(title) do
    title
    |> String.trim()
    |> String.replace(~r/\s+/u, " ")
    |> String.downcase()
  end

  @doc """
  Renders a note to sanitized HTML, with `[[wiki-links]]` turned into real
  links.

  > #### No caller in the UI, on purpose {: .info}
  >
  > There is one editing surface — Leaf — and it renders markdown itself, so
  > nothing in the LiveView calls this today. It is kept because it is the
  > server half of wiki-link rendering: when Leaf learns to display `[[…]]`,
  > this is the function that tells it which links resolve, where they point,
  > and which are dangling. Its tests pin that contract, which is the thing
  > worth not losing.

  `resolver` is called once per distinct link with a `t:wiki_link/0` and must
  return `{:resolved, href}` or `{:unresolved, href}`. Unresolved links get a
  muted, dotted-underline style so a vault's gaps are visible while reading —
  the class survives sanitization, which allows `class` on any tag.

  Front matter is stripped rather than rendered; the properties are shown by
  the UI, not by the prose.
  """
  @spec to_html(String.t() | nil, (wiki_link() -> {:resolved | :unresolved, String.t()})) ::
          String.t()
  def to_html(content, resolver) when is_function(resolver, 1) do
    {_frontmatter, body} = split_frontmatter(content)
    {markdown, decorations} = substitute_wiki_links(body, resolver)

    case MDEx.to_html(markdown, mdex_options()) do
      {:ok, html} ->
        html
        |> HtmlSanitizer.sanitize()
        # After sanitizing, not before: the sanitizer's allowlist drops
        # `data-*`, so decorating first would lose the navigation attributes.
        # Safe to add afterwards because these hrefs are ones this module
        # generated a moment ago, not anything the author wrote.
        |> decorate_wiki_links(decorations)

      {:error, _reason} ->
        # A note that won't parse still has to be readable — show the source
        # rather than an error page.
        markdown |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
    end
  end

  @doc """
  A short plain-text excerpt for note lists — front matter, markdown syntax and
  wiki-link brackets removed.

  Cosmetic only: it is never stored, and never used for search (that is the
  `tsvector` column's job).
  """
  @spec excerpt(String.t() | nil, pos_integer()) :: String.t()
  def excerpt(content, length \\ 160)
  def excerpt(nil, _length), do: ""

  def excerpt(content, length) when is_binary(content) do
    {_frontmatter, body} = split_frontmatter(content)

    body
    |> String.replace(@code_segment_regex, " ")
    |> String.replace(@wiki_link_regex, fn match ->
      case parse_wiki_link(String.slice(match, 2..-3//1)) do
        nil -> " "
        link -> link.label
      end
    end)
    # Leading markdown block syntax: headings, quotes, list bullets, rules.
    |> String.replace(~r/^\s{0,3}(\#{1,6}\s+|>\s?|[-*+]\s+|\d+\.\s+|[-*_]{3,}\s*$)/m, "")
    # Inline emphasis and link syntax, keeping the visible text.
    |> String.replace(~r/!?\[([^\]]*)\]\([^)]*\)/, "\\1")
    |> String.replace(~r/[*_~]{1,3}/, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> truncate(length)
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp truncate(text, length) when byte_size(text) <= length, do: text

  defp truncate(text, length) do
    case String.length(text) <= length do
      true -> text
      false -> text |> String.slice(0, length) |> String.trim_trailing() |> Kernel.<>("…")
    end
  end

  defp substitute_wiki_links(body, resolver) do
    resolutions =
      body
      |> wiki_links()
      |> Map.new(fn link -> {link.key, resolver.(link)} end)

    # href => status, so a title linked from three places is decorated once.
    decorations = Map.new(resolutions, fn {_key, {status, href}} -> {href, status} end)

    markdown =
      map_prose_segments(body, fn segment ->
        Regex.replace(@wiki_link_regex, segment, &replace_one_link(&1, &2, resolutions))
      end)

    {markdown, decorations}
  end

  # A `[[...]]` this pass could not resolve is left exactly as the author wrote
  # it, rather than becoming a dead link.
  defp replace_one_link(full, inner, resolutions) do
    with link when not is_nil(link) <- parse_wiki_link(inner),
         {_status, href} <- Map.get(resolutions, link.key) do
      "[#{escape_link_label(link.label)}](#{href})"
    else
      _ -> full
    end
  end

  # Matching on `<a href="...">` up to and including the closing quote — without
  # it, a link to `/notes/abc` would also match `/notes/abcd`. The `&` is
  # entity-escaped because that is how it appears in the rendered HTML.
  defp decorate_wiki_links(html, decorations) do
    Enum.reduce(decorations, html, fn {href, status}, acc ->
      escaped = String.replace(href, "&", "&amp;")
      anchor = ~s(<a href="#{escaped}")

      String.replace(acc, anchor, anchor <> link_attributes(status))
    end)
  end

  # `redirect` rather than `patch`: it is live navigation either way, but
  # `redirect` does not assume the target route is served by the LiveView the
  # reader is currently on.
  defp link_attributes(:unresolved) do
    ~s( class="#{@unresolved_link_class}" data-phx-link="redirect" data-phx-link-state="push")
  end

  defp link_attributes(:resolved) do
    ~s( data-phx-link="redirect" data-phx-link-state="push")
  end

  # `[` and `]` would terminate the markdown link label early; a trailing
  # backslash would escape the closing bracket.
  defp escape_link_label(label) do
    label
    |> String.replace("\\", "\\\\")
    |> String.replace("[", "\\[")
    |> String.replace("]", "\\]")
  end

  # Split into alternating prose/code segments and keep only the prose ones.
  defp prose_segments(text) do
    text
    |> split_segments()
    |> Enum.filter(fn {kind, _segment} -> kind == :prose end)
    |> Enum.map(fn {_kind, segment} -> segment end)
  end

  # Apply `fun` to prose segments, leaving code untouched, then rejoin.
  defp map_prose_segments(text, fun) do
    text
    |> split_segments()
    |> Enum.map_join("", fn
      {:prose, segment} -> fun.(segment)
      {:code, segment} -> segment
    end)
  end

  defp split_segments(text) do
    @code_segment_regex
    |> Regex.split(text, include_captures: true)
    |> Enum.map(fn segment ->
      if Regex.match?(~r{\A(```|~~~|`)}, segment), do: {:code, segment}, else: {:prose, segment}
    end)
  end

  defp frontmatter_tags(frontmatter) do
    case Map.get(frontmatter, "tags") || Map.get(frontmatter, "tag") do
      nil -> []
      list when is_list(list) -> Enum.map(list, &to_string/1)
      value when is_binary(value) -> String.split(value, [",", " "], trim: true)
      other -> [to_string(other)]
    end
  end

  defp inline_tags(body) do
    body
    |> prose_segments()
    |> Enum.flat_map(&Regex.scan(@inline_tag_regex, &1, capture: :all_but_first))
    |> Enum.map(fn [tag] -> tag end)
  end

  defp normalize_tag(tag) do
    tag
    |> to_string()
    |> String.trim()
    |> String.trim_leading("#")
    |> String.trim("/")
    |> String.downcase()
  end

  # YamlElixir yields plain strings, numbers, booleans, nil, lists and maps —
  # all jsonb-safe. Anything else would crash the insert at encode time, well
  # away from the note that caused it, so it is stringified here instead.
  defp jsonable(%{} = map) when not is_struct(map) do
    Map.new(map, fn {key, value} -> {to_string(key), jsonable(value)} end)
  end

  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp jsonable(nil), do: nil
  defp jsonable(value) when is_atom(value), do: to_string(value)
  defp jsonable(value), do: inspect(value)

  # Mirrors core's `<.markdown>` component so a note renders the same as every
  # other piece of markdown in the admin: GFM, smart typography, raw HTML
  # passed through to the sanitizer rather than escaped early.
  defp mdex_options do
    [
      extension: [strikethrough: true, table: true, autolink: true, tasklist: true],
      parse: [smart: true],
      render: [unsafe: true]
    ]
  end
end
