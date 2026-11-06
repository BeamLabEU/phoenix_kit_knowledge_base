defmodule PhoenixKitKnowledgeBase.Links do
  @moduledoc """
  The `[[wiki-link]]` index: backlinks, unresolved links, and the resolution
  rules that make a bare `[[Title]]` unambiguous when the filesystem allows two
  files to share a name.

  The index is a cache of the markdown, rebuilt whenever a note's bytes change,
  and reproducible from scratch by re-reading the vault.

  ## Resolving a link

  A vault may legitimately hold `research/Ideas.md` and `archive/Ideas.md` —
  the filesystem permits it, so the index has to describe it rather than reject
  it. `[[Ideas]]` therefore resolves by:

    1. a note in the **same folder** as the linking note, then
    2. the **shortest path** (a note nearer the vault root is the more general
       one, and the likelier intent), then
    3. alphabetical order, purely so the answer is stable rather than
       whichever row Postgres returned first.

  Write `[[research/Ideas]]` to say exactly which one you meant. Path-qualified
  links are matched against the path instead of the title, and never ambiguous.

  ## Unresolved links are a feature

  A link to a note that does not exist is stored as a real row with a nil
  `target_note_uuid` rather than discarded, so clicking a dangling link offers
  to create that note, the vault can list everything it has referred to but not
  written, and creating a note **retroactively resolves** every link already
  pointing at its title. Deleting a note runs it backwards: `nilify_all` turns
  links into it back into unresolved ones, so the mentions survive the target.
  """

  import Ecto.Query

  alias PhoenixKitKnowledgeBase.Markdown
  alias PhoenixKitKnowledgeBase.Schemas.{Note, NoteLink}
  alias PhoenixKitKnowledgeBase.Storage

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ── Resolution ────────────────────────────────────────────────────────────

  @typedoc "Everything needed to resolve links in one vault, loaded once."
  @type resolver :: %{by_title: %{String.t() => [Note.t()]}, by_path: %{String.t() => Note.t()}}

  @doc """
  Load a vault's notes into a structure that can resolve any link without
  further queries.

  Built once per render or per reindex pass. Resolving link-by-link would be a
  query per `[[…]]` on the page, and a query per link per note during a rescan.
  """
  @spec resolver(String.t()) :: resolver()
  def resolver(vault_uuid) do
    notes =
      repo().all(
        from(n in Note,
          where: n.vault_uuid == ^vault_uuid,
          select: %{
            uuid: n.uuid,
            title_key: n.title_key,
            relative_path: n.relative_path,
            folder_path: n.folder_path
          }
        )
      )

    resolver_from(notes)
  end

  @doc """
  A resolver over the given notes only — for a notes panel, whose links must
  resolve inside its own folder and nowhere else: a title from outside it is
  somebody else's note, and saying it exists would tell its name to a person who
  may only see this folder. Each note needs `title_key`, `relative_path` and
  `folder_path`.
  """
  @spec resolver_from([map()]) :: resolver()
  def resolver_from(notes) do
    %{
      by_title: Enum.group_by(notes, & &1.title_key),
      by_path: Map.new(notes, &{path_key(&1.relative_path), &1})
    }
  end

  @doc """
  The note a link points at, or `nil` when nothing matches.

  `from_folder` is the linking note's folder, which is what makes the
  same-folder tie-break possible; pass `""` from the vault root.
  """
  @spec resolve(resolver(), String.t(), String.t()) :: map() | nil
  def resolve(resolver, key, from_folder \\ "")

  def resolve(_resolver, key, _from_folder) when key in [nil, ""], do: nil

  def resolve(resolver, key, from_folder) do
    if String.contains?(key, "/") do
      # Path-qualified: exact, and never ambiguous.
      Map.get(resolver.by_path, key)
    else
      resolver.by_title |> Map.get(key, []) |> pick_best(from_folder)
    end
  end

  @doc """
  How many notes a bare title could refer to.

  Used by the UI to mark a link ambiguous — the link still resolves, but it is
  worth telling the author that their `[[Ideas]]` had to be guessed at.
  """
  @spec candidate_count(resolver(), String.t()) :: non_neg_integer()
  def candidate_count(resolver, key) when is_binary(key) do
    if String.contains?(key, "/") do
      if Map.has_key?(resolver.by_path, key), do: 1, else: 0
    else
      resolver.by_title |> Map.get(key, []) |> length()
    end
  end

  def candidate_count(_resolver, _key), do: 0

  defp pick_best([], _from_folder), do: nil
  defp pick_best([only], _from_folder), do: only

  defp pick_best(candidates, from_folder) do
    Enum.min_by(candidates, fn note ->
      {
        # `false` sorts before `true`, so negate: same folder wins.
        if(note.folder_path == from_folder, do: 0, else: 1),
        String.length(note.relative_path),
        note.relative_path
      }
    end)
  end

  @doc "The normalised form of a path, matching what a path-qualified link normalises to."
  @spec path_key(String.t()) :: String.t()
  def path_key(relative_path) do
    relative_path
    |> Storage.drop_extension()
    |> Markdown.normalize_title()
  end

  # ── Indexing ──────────────────────────────────────────────────────────────

  @doc """
  Rebuild the outgoing link rows for one note.

  Deletes and re-inserts rather than diffing: a note has a handful of links, and
  "delete what's there, insert what the text says" cannot drift, whereas a diff
  can.
  """
  @spec reindex_note(Note.t(), resolver() | nil) :: :ok
  def reindex_note(note, resolver \\ nil)

  def reindex_note(%Note{} = note, nil), do: reindex_note(note, resolver(note.vault_uuid))

  def reindex_note(%Note{} = note, resolver) do
    {_frontmatter, body} = Markdown.split_frontmatter(note.content || "")
    now = DateTime.utc_now()

    rows =
      body
      |> Markdown.wiki_links()
      |> Enum.map(fn link ->
        target = resolve(resolver, link.key, note.folder_path || "")

        %{
          vault_uuid: note.vault_uuid,
          source_note_uuid: note.uuid,
          target_note_uuid: target && target.uuid,
          target_key: link.key,
          target_title: link.target,
          inserted_at: now,
          updated_at: now
        }
      end)
      # A note linking to itself produces a self-backlink, which is only noise.
      |> Enum.reject(&(&1.target_note_uuid == note.uuid))

    repo().delete_all(from(l in NoteLink, where: l.source_note_uuid == ^note.uuid))
    if rows != [], do: repo().insert_all(NoteLink, rows)

    :ok
  end

  @doc """
  Rebuild every link in a vault.

  Used after a rescan. Incremental updates cannot be correct there: adding one
  note can change what an *existing* link resolves to, because a nearer
  same-name file may have appeared. Rebuilding the lot is O(notes) once, and it
  is the only version of this that is actually right.
  """
  @spec reindex_vault(String.t()) :: non_neg_integer()
  def reindex_vault(vault_uuid) do
    resolver = resolver(vault_uuid)
    notes = repo().all(from(n in Note, where: n.vault_uuid == ^vault_uuid))

    Enum.each(notes, &reindex_note(&1, resolver))
    length(notes)
  end

  @doc """
  Point unresolved links at a note that now exists.

  Matches both spellings a link can take: the bare title, and the
  path-qualified form.
  """
  @spec resolve_for_note(Note.t()) :: non_neg_integer()
  def resolve_for_note(%Note{} = note) do
    keys = Enum.uniq([note.title_key, path_key(note.relative_path)])

    {count, _} =
      repo().update_all(
        from(l in NoteLink,
          where:
            l.vault_uuid == ^note.vault_uuid and
              l.target_key in ^keys and
              is_nil(l.target_note_uuid) and
              l.source_note_uuid != ^note.uuid
        ),
        set: [target_note_uuid: note.uuid, updated_at: DateTime.utc_now()]
      )

    count
  end

  @doc """
  The two keys a note answers to: its bare title, and its path-qualified form.
  """
  @spec keys_for(Note.t()) :: [String.t()]
  def keys_for(%Note{} = note), do: Enum.uniq([note.title_key, path_key(note.relative_path)])

  @doc """
  Re-resolve every link in a vault that names one of `keys`, whether or not it
  currently resolves.

  This is the difference between `resolve_for_note/1` and being *right*.
  `resolve_for_note/1` only fills rows where `target_note_uuid` is nil, so an
  already-resolved link stays pointed at whichever note got there first:

    1. `archive/A.md` writes `[[Ideas]]` — nothing to resolve to, so unresolved
    2. `research/Ideas.md` is created — the link now points at research
    3. `archive/Ideas.md` is created — same-folder should win, but the row is
       already resolved, so it does not move until a full rescan

  Step 3 contradicts the resolution rules at the top of this module, which is a
  worse bug than it looks: the link renders as resolved, so nothing tells the
  author it went to the wrong note.

  Scoped by key rather than rebuilding the vault, because only links *naming*
  the changed note can change meaning. The work is proportional to how many
  notes mention that title, not to vault size, which is what makes it cheap
  enough to run on every create, rename, move, restore and delete.
  """
  @spec reresolve_keys(String.t(), [String.t()]) :: non_neg_integer()
  def reresolve_keys(vault_uuid, keys)

  def reresolve_keys(_vault_uuid, []), do: 0

  def reresolve_keys(vault_uuid, keys) do
    keys = Enum.uniq(keys)
    resolver = resolver(vault_uuid)
    now = DateTime.utc_now()

    # The source note's folder is what makes the same-folder tie-break possible,
    # so it has to come back with the row.
    rows =
      repo().all(
        from(l in NoteLink,
          join: source in Note,
          on: source.uuid == l.source_note_uuid,
          where: l.vault_uuid == ^vault_uuid and l.target_key in ^keys,
          select: %{
            uuid: l.uuid,
            target_key: l.target_key,
            current: l.target_note_uuid,
            source_uuid: l.source_note_uuid,
            from_folder: source.folder_path
          }
        )
      )

    rows
    |> changed_targets(resolver)
    # Grouped so a title mentioned by fifty notes is two updates, not fifty.
    |> Enum.group_by(fn {_uuid, target_uuid} -> target_uuid end, fn {uuid, _} -> uuid end)
    |> Enum.reduce(0, fn {target_uuid, link_uuids}, acc ->
      {count, _} =
        repo().update_all(
          from(l in NoteLink, where: l.uuid in ^link_uuids),
          set: [target_note_uuid: target_uuid, updated_at: now]
        )

      acc + count
    end)
  end

  @doc false
  # The decision half of `reresolve_keys/2`, split out because it is the part
  # that can be wrong: which links should now point somewhere else, as
  # `{link_uuid, new_target_uuid}`. Pure, so the tie-break can be tested without
  # a database — same as `resolve/3`.
  @spec changed_targets([map()], resolver()) :: [{term(), String.t() | nil}]
  def changed_targets(rows, resolver) do
    rows
    |> Enum.map(&{&1, intended_target(resolver, &1)})
    # Only rows whose answer actually changed are written.
    |> Enum.reject(fn {row, target_uuid} -> row.current == target_uuid end)
    |> Enum.map(fn {row, target_uuid} -> {row.uuid, target_uuid} end)
  end

  @doc "Re-resolve every link naming this note, under either of its keys."
  @spec reresolve_for_note(Note.t()) :: non_neg_integer()
  def reresolve_for_note(%Note{} = note), do: reresolve_keys(note.vault_uuid, keys_for(note))

  # A note that links to itself is left unresolved rather than pointed at its
  # own source — `reindex_note/2` drops those rows for the same reason, and a
  # self-backlink is only noise.
  defp intended_target(resolver, row) do
    case resolve(resolver, row.target_key, row.from_folder || "") do
      nil -> nil
      %{uuid: uuid} when uuid == row.source_uuid -> nil
      %{uuid: uuid} -> uuid
    end
  end

  # ── Reads ─────────────────────────────────────────────────────────────────

  @doc "Notes that link *to* this one — the 'linked mentions' panel, in title order."
  @spec backlinks(Note.t()) :: [Note.t()]
  def backlinks(%Note{uuid: uuid}) do
    repo().all(
      from(l in NoteLink,
        join: source in Note,
        on: source.uuid == l.source_note_uuid,
        where: l.target_note_uuid == ^uuid,
        order_by: [asc: source.title, asc: source.relative_path],
        select: source
      )
    )
  end

  @doc "Distinct outgoing links from a note, resolved and unresolved, in title order."
  @spec outgoing(Note.t()) :: [NoteLink.t()]
  def outgoing(%Note{uuid: uuid}) do
    repo().all(
      from(l in NoteLink, where: l.source_note_uuid == ^uuid, order_by: [asc: l.target_title])
    )
  end

  @doc """
  Every unresolved target in a vault, with how many notes want it.

  Sorted by mention count: the note five others already reference is a better
  next thing to write than one mentioned once.
  """
  @spec unresolved(String.t()) :: [
          %{title: String.t(), key: String.t(), count: non_neg_integer()}
        ]
  def unresolved(vault_uuid) do
    repo().all(
      from(l in NoteLink,
        where: l.vault_uuid == ^vault_uuid and is_nil(l.target_note_uuid),
        group_by: [l.target_key],
        order_by: [desc: count(l.uuid), asc: min(l.target_title)],
        select: %{
          key: l.target_key,
          # Different notes may spell it differently ("API" / "api"); show one.
          title: min(l.target_title),
          count: count(l.uuid)
        }
      )
    )
  end

  @doc "How many distinct unresolved targets a vault has."
  @spec unresolved_count(String.t()) :: non_neg_integer()
  def unresolved_count(vault_uuid) do
    repo().one(
      from(l in NoteLink,
        where: l.vault_uuid == ^vault_uuid and is_nil(l.target_note_uuid),
        select: count(fragment("DISTINCT ?", l.target_key))
      )
    ) || 0
  end
end
