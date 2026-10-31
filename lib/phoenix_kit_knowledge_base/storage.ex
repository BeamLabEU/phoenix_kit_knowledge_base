defmodule PhoenixKitKnowledgeBase.Storage do
  @moduledoc """
  The filesystem layer. Files on disk are the source of truth; Postgres is an
  index of them.

  ## Layout

      <root>/system/<vault-slug>/…                    organisation vaults
      <root>/users/<email-slug>/<vault-slug>/…        personal vaults

  Inside a vault, directories are folders and `<Title>.md` is a note — the same
  shape Obsidian uses, so `mv`, `rm`, `rg`, `git` and Obsidian itself all work
  on the tree directly.

  Configure the root (defaults to `priv/knowledge_base` under the running app's
  working directory, which is the host Phoenix project in dev):

      config :phoenix_kit_knowledge_base, root: "/www/app/priv/knowledge_base"

  ## Path safety

  Every path that reaches the filesystem is built from user-supplied text — note
  titles, folder names, vault slugs — so containment is enforced twice, in two
  different ways, because this is the one place in the module where a bug is a
  server compromise rather than a bad page:

    1. `safe_relative/1` rejects the input outright — absolute paths, any `.` or
       `..` segment, and NUL bytes never become a path at all.
    2. `resolve/2` expands the joined result and re-checks that it is still
       under the base. That catches anything the first pass didn't anticipate,
       including a base that itself contains symlinks.

  Symlinks *inside* a vault are skipped by the walk rather than followed, so a
  planted link can't pull `/etc/passwd` into someone's search index. The vault
  directory itself may be a symlink — that is how you point a vault at an
  Obsidian vault that already exists somewhere else.

  ## Atomic writes

  `write_note/3` writes to a temporary file in the same directory and renames it
  into place. `rename/2` within a filesystem is atomic, so a reader — `rg`, a
  rescan, Obsidian — never observes a half-written note, and a crash mid-write
  leaves the previous version intact rather than a truncated file.
  """

  require Logger

  @extension ".md"
  # Obsidian keeps deleted notes in `.trash` inside the vault too, so this uses
  # the same directory. Being a dotfile, it is skipped by the walk, which is
  # what keeps trashed notes out of the index, out of search and out of the
  # link graph without any special-casing.
  @trash_dir ".trash"
  @default_root "priv/knowledge_base"

  # Exactly the set Obsidian refuses, and for the same two reasons.
  #
  # `* " \ / < > : | ?` are illegal or hostile in a path segment on some
  # filesystem someone will eventually sync this vault to.
  #
  # `[ ] # ^ |` break link syntax: a note called `Ideas [draft]` cannot be
  # written as `[[Ideas [draft]]]`, and `#` and `^` are heading, tag and
  # block-reference markers inside a link target. A title that cannot be linked
  # to is close to useless in a vault whose whole point is linking.
  @forbidden_filename_chars ~c"/\\:*?\"<>|[]#^"

  # Bounded in bytes, not characters — that is what filesystems limit. 255 is the
  # common ceiling; the margin leaves room for `.md` and for a trash timestamp
  # path to be built on top without overflowing.
  @max_filename_bytes 200

  @typedoc "A file found by `list_notes/1`: path relative to the vault directory, plus cheap change-detection metadata."
  @type entry :: %{
          relative_path: String.t(),
          mtime: DateTime.t(),
          size: non_neg_integer()
        }

  # ── Root and vault directories ────────────────────────────────────────────

  @doc """
  The configured root directory for all vaults.

  Relative configuration is resolved against the current working directory,
  which in a Phoenix app is the project root — so the default lands on
  `priv/knowledge_base` inside the host app.
  """
  @spec root() :: String.t()
  def root do
    :phoenix_kit_knowledge_base
    |> Application.get_env(:root, @default_root)
    |> Path.expand()
  end

  @doc """
  The directory a vault's files live in, relative to `root/0`.

  Computed once when the vault is created and then stored on the row, never
  recomputed: a personal vault's path contains a slug of its owner's email, and
  silently relocating someone's notes because they changed their email address
  would be a spectacular way to lose a vault.
  """
  @spec build_directory(:system | :user, String.t(), String.t() | nil) :: String.t()
  def build_directory(:system, vault_slug, _owner_email), do: Path.join("system", vault_slug)

  def build_directory(:user, vault_slug, owner_email) do
    Path.join(["users", email_slug(owner_email), vault_slug])
  end

  @doc """
  Turns an email address into a readable, safe directory segment.

  `fotkin@gmail.com` becomes `fotkin-gmail-com`. Falls back to `user` for input
  with nothing usable in it, so the path is always well-formed — the vault slug
  underneath it is what actually keeps the directory unique.
  """
  @spec email_slug(String.t() | nil) :: String.t()
  def email_slug(nil), do: "user"

  def email_slug(email) when is_binary(email) do
    slug =
      email
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    if slug == "", do: "user", else: slug
  end

  @doc "Absolute path to a vault's directory."
  @spec vault_path(String.t()) :: String.t()
  def vault_path(directory), do: Path.join(root(), directory)

  # ── Path safety ───────────────────────────────────────────────────────────

  @doc """
  Validates a caller-supplied relative path.

  Returns `{:ok, normalised}` or `:error`. The empty string is valid and means
  "the vault root", which is how a note at the top level is addressed.
  """
  @spec safe_relative(String.t() | nil) :: {:ok, String.t()} | :error
  def safe_relative(nil), do: :error
  def safe_relative(""), do: {:ok, ""}

  def safe_relative(path) when is_binary(path) do
    cond do
      String.contains?(path, <<0>>) -> :error
      Path.type(path) != :relative -> :error
      true -> validate_segments(path)
    end
  end

  def safe_relative(_), do: :error

  defp validate_segments(path) do
    segments =
      path
      |> Path.split()
      |> Enum.reject(&(&1 == "."))

    cond do
      # `..` at any depth, not just the front: `a/../../etc` escapes too.
      Enum.any?(segments, &(&1 == "..")) -> :error
      segments == [] -> {:ok, ""}
      true -> {:ok, Path.join(segments)}
    end
  end

  @doc """
  Joins a validated relative path onto a base and confirms the result is still
  inside it.

  The second, redundant-looking check is the point: `safe_relative/1` reasons
  about the string, this reasons about the resolved path. Either alone has been
  enough to produce a traversal bug in somebody's codebase.
  """
  @spec resolve(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, :unsafe_path}
  def resolve(base, relative) do
    with {:ok, safe} <- safe_relative(relative),
         expanded_base <- Path.expand(base),
         candidate <- Path.expand(Path.join(expanded_base, safe)),
         true <- contained?(candidate, expanded_base) do
      {:ok, candidate}
    else
      _ -> {:error, :unsafe_path}
    end
  end

  defp contained?(candidate, base) do
    candidate == base or String.starts_with?(candidate, base <> "/")
  end

  @doc """
  Validates one path segment as a filename or folder name.

  Returns `{:ok, trimmed}` or `{:error, reason}`. **Rejects rather than
  repairs** — an earlier version silently stripped offending characters, which
  meant typing `Ideas: Part 2` produced a note called `Ideas Part 2` with no
  explanation and a title that no longer matched what was typed. Obsidian
  reports the problem and lets you fix it; so does this.

  The rules are Obsidian's: no `* " \\ / < > : | ?` (path-hostile), no
  `[ ] # ^` (link-syntax breakers), nothing that would make the file hidden or
  ambiguous.

  Note the asymmetry with indexing. This governs names *this app creates*.
  A file that already exists on disk is indexed whatever it is called — the
  filesystem allowed it, Obsidian may have made it, and refusing to show
  someone's note because of its name would be worse than the name.
  """
  @spec validate_filename(String.t() | nil) ::
          {:ok, String.t()}
          | {:error,
             :blank
             | :leading_dot
             | :trailing_dot
             | :too_long
             | :reserved
             | {:forbidden_characters, [String.t()]}}
  def validate_filename(nil), do: {:error, :blank}

  def validate_filename(name) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" -> {:error, :blank}
      found = forbidden_in(trimmed) -> {:error, {:forbidden_characters, found}}
      String.starts_with?(trimmed, ".") -> {:error, :leading_dot}
      String.ends_with?(trimmed, ".") -> {:error, :trailing_dot}
      byte_size(trimmed) > @max_filename_bytes -> {:error, :too_long}
      reserved?(trimmed) -> {:error, :reserved}
      true -> {:ok, trimmed}
    end
  end

  def validate_filename(_), do: {:error, :blank}

  defp forbidden_in(name) do
    forbidden = Enum.map(@forbidden_filename_chars, &<<&1::utf8>>)

    found =
      name
      |> String.graphemes()
      |> Enum.filter(fn char ->
        char in forbidden or String.match?(char, ~r/[[:cntrl:]]/u)
      end)
      |> Enum.uniq()

    if found == [], do: nil, else: found
  end

  # Windows device names. This vault may well be synced to a Windows machine by
  # Obsidian, where a file called `CON.md` cannot be created at all — better to
  # refuse it here than to hand someone a vault that fails to sync.
  @reserved_names ~w(con prn aux nul) ++
                    Enum.map(1..9, &"com#{&1}") ++ Enum.map(1..9, &"lpt#{&1}")

  defp reserved?(name), do: String.downcase(name) in @reserved_names

  @doc """
  The characters a note or folder name may not contain, for showing in an error.
  """
  @spec forbidden_characters() :: String.t()
  def forbidden_characters, do: Enum.map_join(@forbidden_filename_chars, " ", &<<&1::utf8>>)

  @doc """
  The relative path a note with this title, in this folder, should live at.

  The filename *is* the title, plus `.md` — Obsidian's scheme, so a note created
  here is indistinguishable from one created there.
  """
  @spec note_relative_path(String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def note_relative_path(title, folder_path \\ nil) do
    with {:ok, filename} <- validate_filename(title),
         {:ok, folder} <- safe_relative(folder_path || "") do
      {:ok, Path.join(folder, filename <> @extension)}
    else
      {:error, reason} -> {:error, reason}
      :error -> {:error, :unsafe_path}
    end
  end

  @doc "The title a note at this path has — its filename without the extension."
  @spec title_from_path(String.t()) :: String.t()
  def title_from_path(relative_path) do
    relative_path |> Path.basename() |> drop_extension() |> String.trim()
  end

  @doc """
  A path without its markdown extension.

  Case-insensitive on purpose: the walk accepts `Note.MD` as readily as
  `Note.md` (`markdown?/1` downcases before comparing), so a title derived
  with a case-sensitive strip would come out as `"Note.MD"` — and a bare
  `[[Note]]` would never resolve to it. Strip the same way the walk matches.
  """
  @spec drop_extension(String.t()) :: String.t()
  def drop_extension(path) when is_binary(path) do
    if String.ends_with?(String.downcase(path), @extension) do
      binary_part(path, 0, byte_size(path) - byte_size(@extension))
    else
      path
    end
  end

  @doc "The folder a note at this path sits in: a relative path, or `\"\"` for the vault root."
  @spec folder_from_path(String.t()) :: String.t()
  def folder_from_path(relative_path) do
    case Path.dirname(relative_path) do
      "." -> ""
      dir -> dir
    end
  end

  @doc "The markdown file extension this module reads and writes."
  @spec extension() :: String.t()
  def extension, do: @extension

  # ── Reading ───────────────────────────────────────────────────────────────

  @doc "Create a vault's directory (and any missing parents)."
  @spec ensure_vault(String.t()) :: :ok | {:error, term()}
  def ensure_vault(directory) do
    with {:ok, path} <- resolve(root(), directory) do
      File.mkdir_p(path)
    end
  end

  @doc "Create a folder inside a vault."
  @spec create_folder(String.t(), String.t()) :: :ok | {:error, term()}
  def create_folder(directory, folder_path) do
    with {:ok, path} <- vault_child(directory, folder_path) do
      File.mkdir_p(path)
    end
  end

  @doc "Delete a folder and everything under it. Notes inside go with it — the caller warns first."
  @spec delete_folder(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_folder(directory, folder_path) do
    with {:ok, path} <- vault_child(directory, folder_path),
         # Refuse to rm -rf the vault root because a caller passed "" or ".".
         true <- Path.expand(path) != Path.expand(vault_path(directory)),
         {:ok, _} <- File.rm_rf(path) do
      :ok
    else
      false -> {:error, :refuse_vault_root}
      {:error, reason} -> {:error, reason}
      error -> error
    end
  end

  @doc """
  Move a folder, which is how both renaming and reparenting are done.

  There is one operation here because on a filesystem there is one operation:
  renaming `research` to `archive` and moving it into `2026/` are both a
  directory rename, and pretending otherwise would mean two code paths that can
  disagree.

  Four things are refused rather than attempted:

    * the vault root, in either position — moving it means moving the vault
    * a target that already exists, so nothing is merged or clobbered
    * moving a folder **into its own subtree**, which orphans the directory
      being moved along with everything under it
    * anything outside the vault, by the same containment check as every other
      path here

  The caller reindexes afterwards. This only moves bytes.
  """
  @spec move_folder(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def move_folder(directory, from, to) do
    with {:ok, source} <- vault_child(directory, from),
         {:ok, target} <- vault_child(directory, to),
         root = Path.expand(vault_path(directory)),
         :ok <- refuse_vault_root(source, target, root),
         :ok <- refuse_descendant(source, target),
         false <- File.exists?(target),
         :ok <- File.mkdir_p(Path.dirname(target)) do
      File.rename(source, target)
    else
      true -> {:error, :target_exists}
      {:error, reason} -> {:error, reason}
      error -> error
    end
  end

  defp refuse_vault_root(source, target, root) do
    if Path.expand(source) == root or Path.expand(target) == root do
      {:error, :refuse_vault_root}
    else
      :ok
    end
  end

  # `research` -> `research/old` renames a directory into a path that only
  # exists inside the directory being renamed. `File.rename/2` reports this as
  # `:einval` on Linux, but the message says nothing useful and the check is one
  # line — and on a filesystem that allowed it, the result would be unreachable.
  #
  # Compared with a trailing separator so `researching` is not read as being
  # inside `research`.
  defp refuse_descendant(source, target) do
    source_prefix = Path.expand(source) <> "/"

    if String.starts_with?(Path.expand(target) <> "/", source_prefix) do
      {:error, :refuse_descendant}
    else
      :ok
    end
  end

  @doc "Read a note's raw markdown."
  @spec read_note(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def read_note(directory, relative_path) do
    with {:ok, path} <- vault_child(directory, relative_path) do
      File.read(path)
    end
  end

  @doc """
  A note's current size, mtime and content hash — everything rescan needs to
  decide whether the index is stale, and what the stale-write guard compares
  against.
  """
  @spec stat_note(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def stat_note(directory, relative_path) do
    with {:ok, path} <- vault_child(directory, relative_path),
         {:ok, %File.Stat{} = stat} <- File.stat(path, time: :posix),
         {:ok, content} <- File.read(path) do
      {:ok,
       %{
         size: stat.size,
         mtime: DateTime.from_unix!(stat.mtime),
         hash: hash(content),
         content: content
       }}
    end
  end

  @doc "SHA-256 of a note's bytes, hex encoded. Used for change and rename detection."
  @spec hash(binary()) :: String.t()
  def hash(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  @doc """
  Every markdown file in a vault, with the metadata rescan compares.

  Skips dotfiles and dot-directories (`.obsidian`, `.git`, `.trash`) and skips
  symlinks rather than following them.
  """
  @spec list_notes(String.t()) :: {:ok, [entry()]} | {:error, term()}
  def list_notes(directory) do
    with {:ok, base} <- resolve(root(), directory) do
      if File.dir?(base) do
        {:ok, walk(base, base, [])}
      else
        # A vault whose directory was deleted underneath us reads as empty
        # rather than an error — rescan then reports every note as removed,
        # which is the truth.
        {:ok, []}
      end
    end
  end

  @doc "Every directory in a vault, as paths relative to it."
  @spec list_folders(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_folders(directory) do
    with {:ok, base} <- resolve(root(), directory) do
      if File.dir?(base), do: {:ok, walk_dirs(base, base, [])}, else: {:ok, []}
    end
  end

  defp walk(base, dir, acc) do
    case File.ls(dir) do
      {:ok, names} -> Enum.reduce(names, acc, &visit(base, dir, &1, &2))
      {:error, _reason} -> acc
    end
  end

  defp visit(base, dir, name, acc) do
    full = Path.join(dir, name)

    cond do
      hidden?(name) -> acc
      symlink?(full) -> acc
      File.dir?(full) -> walk(base, full, acc)
      markdown?(name) -> add_entry(base, full, acc)
      true -> acc
    end
  end

  defp add_entry(base, full, acc) do
    case File.stat(full, time: :posix) do
      {:ok, stat} ->
        [
          %{
            relative_path: Path.relative_to(full, base),
            mtime: DateTime.from_unix!(stat.mtime),
            size: stat.size
          }
          | acc
        ]

      {:error, _reason} ->
        acc
    end
  end

  defp walk_dirs(base, dir, acc) do
    case File.ls(dir) do
      {:ok, names} -> Enum.reduce(names, acc, &visit_dir(base, dir, &1, &2))
      {:error, _reason} -> acc
    end
  end

  defp visit_dir(base, dir, name, acc) do
    full = Path.join(dir, name)

    if hidden?(name) or symlink?(full) or not File.dir?(full) do
      acc
    else
      walk_dirs(base, full, [Path.relative_to(full, base) | acc])
    end
  end

  defp hidden?(name), do: String.starts_with?(name, ".")

  defp markdown?(name), do: String.ends_with?(String.downcase(name), @extension)

  # `lstat`, not `stat`: `stat` follows the link and would report the target's
  # type, which is exactly what we're trying not to trust.
  defp symlink?(path) do
    match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))
  end

  # ── Writing ───────────────────────────────────────────────────────────────

  @doc """
  Write a note atomically and return its fresh stat.

  Temp file in the same directory, then rename — a rename within one filesystem
  is atomic, so nothing ever reads a partial note and a crash mid-write leaves
  the old content in place.
  """
  @spec write_note(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def write_note(directory, relative_path, content) do
    with {:ok, path} <- vault_child(directory, relative_path),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- atomic_write(path, content) do
      stat_note(directory, relative_path)
    end
  end

  defp atomic_write(path, content) do
    temp = path <> ".tmp." <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    with :ok <- File.write(temp, content),
         :ok <- File.rename(temp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temp)
        {:error, reason}
    end
  end

  @doc """
  Move a note into the vault's trash instead of unlinking it.

  The trashed copy keeps its original path under a per-deletion timestamp
  directory — `.trash/1756150000/research/Ideas.md`. That shape is doing real
  work: the original path is recoverable verbatim (restore is a move, with no
  name to un-mangle), and deleting, recreating and deleting the same note again
  produces two independent copies rather than one overwriting the other.

  A missing file yields `{:ok, nil}`: the desired state is "not in the vault",
  and there is nothing to recover.
  """
  @spec trash_note(String.t(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def trash_note(directory, relative_path) do
    with {:ok, source} <- vault_child(directory, relative_path) do
      if File.exists?(source) do
        move_into_trash(directory, source, relative_path)
      else
        {:ok, nil}
      end
    end
  end

  @doc """
  Move a whole folder into the trash, subtree intact.
  """
  @spec trash_folder(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def trash_folder(directory, folder_path) do
    with {:ok, source} <- vault_child(directory, folder_path),
         # Trashing "" or "." would move the entire vault into its own trash.
         true <- Path.expand(source) != Path.expand(vault_path(directory)) do
      move_into_trash(directory, source, folder_path)
    else
      false -> {:error, :refuse_vault_root}
      other -> other
    end
  end

  defp move_into_trash(directory, source, relative_path) do
    trash_relative = Path.join([@trash_dir, deletion_stamp(), relative_path])

    with {:ok, target} <- vault_child(directory, trash_relative),
         :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.rename(source, target) do
      {:ok, trash_relative}
    end
  end

  # `<unix-seconds>-<random>`, not a bare timestamp. Deleting a note, recreating
  # it and deleting it again inside the same second produced the same directory,
  # and the second `rename` silently overwrote the first recoverable copy — the
  # one thing a trash exists to prevent. The suffix makes each deletion its own
  # directory; the seconds prefix is still what `deleted_at` is read from.
  defp deletion_stamp do
    seconds = System.system_time(:second)
    suffix = 3 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    "#{seconds}-#{suffix}"
  end

  @doc """
  Everything in the vault's trash, newest first.

  Each entry reports where it came from and when it was deleted, both read
  straight out of the path.
  """
  @spec list_trash(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_trash(directory) do
    with {:ok, base} <- vault_child(directory, @trash_dir) do
      if File.dir?(base) do
        {:ok, base |> trash_entries() |> Enum.sort_by(& &1.deleted_at, {:desc, DateTime})}
      else
        {:ok, []}
      end
    end
  end

  defp trash_entries(base) do
    case File.ls(base) do
      {:ok, stamps} -> Enum.flat_map(stamps, &trash_entries_for_stamp(base, &1))
      {:error, _reason} -> []
    end
  end

  defp trash_entries_for_stamp(base, stamp) do
    with {:ok, seconds} <- parse_stamp(stamp),
         {:ok, deleted_at} <- DateTime.from_unix(seconds),
         stamp_dir <- Path.join(base, stamp),
         true <- File.dir?(stamp_dir) do
      stamp_dir
      |> walk(stamp_dir, [])
      |> Enum.map(fn entry ->
        %{
          # Path inside the vault, for restoring or purging.
          trash_path: Path.join([@trash_dir, stamp, entry.relative_path]),
          # Where it lived before deletion.
          original_path: entry.relative_path,
          title: title_from_path(entry.relative_path),
          deleted_at: deleted_at,
          size: entry.size
        }
      end)
    else
      # A directory in `.trash` that this app did not create — left alone rather
      # than guessed at.
      _ -> []
    end
  end

  # The seconds prefix of a deletion directory. Anything else in `.trash` was
  # not put there by this app — Obsidian's own trash, say — and is left alone
  # rather than guessed at.
  defp parse_stamp(stamp) do
    case stamp |> String.split("-", parts: 2) |> hd() |> Integer.parse() do
      {seconds, ""} when seconds > 0 -> {:ok, seconds}
      _ -> :error
    end
  end

  @doc """
  Move a trashed note back to where it came from.

  Refuses when something already occupies the original path: restoring must
  never overwrite a note that was written since.
  """
  @spec restore(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def restore(directory, trash_path, original_path) do
    with {:ok, source} <- vault_child(directory, trash_path),
         {:ok, target} <- vault_child(directory, original_path),
         false <- File.exists?(target),
         :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.rename(source, target) do
      :ok
    else
      true -> {:error, :target_exists}
      other -> other
    end
  end

  @doc "Delete one trashed item for good."
  @spec purge(String.t(), String.t()) :: :ok | {:error, term()}
  def purge(directory, trash_path) do
    with {:ok, path} <- vault_child(directory, trash_path),
         true <- String.starts_with?(trash_path, @trash_dir <> "/"),
         {:ok, _} <- File.rm_rf(path) do
      :ok
    else
      # A "purge" pointed outside the trash is a delete of a live note wearing
      # the wrong name — refuse rather than resolve it.
      false -> {:error, :not_in_trash}
      other -> other
    end
  end

  @doc "Empty the vault's trash."
  @spec empty_trash(String.t()) :: :ok | {:error, term()}
  def empty_trash(directory) do
    with {:ok, path} <- vault_child(directory, @trash_dir),
         {:ok, _} <- File.rm_rf(path) do
      :ok
    end
  end

  @doc "The trash directory name, relative to a vault."
  @spec trash_dir() :: String.t()
  def trash_dir, do: @trash_dir

  @doc """
  Move or rename a note.

  Refuses to overwrite an existing file: a rename that silently destroys another
  note is worse than a rename that fails.
  """
  @spec move_note(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def move_note(directory, from, to) do
    with {:ok, source} <- vault_child(directory, from),
         {:ok, target} <- vault_child(directory, to),
         false <- File.exists?(target) and source != target,
         :ok <- File.mkdir_p(Path.dirname(target)) do
      File.rename(source, target)
    else
      true -> {:error, :target_exists}
      {:error, reason} -> {:error, reason}
      error -> error
    end
  end

  @doc "True when a note's file already exists."
  @spec note_exists?(String.t(), String.t()) :: boolean()
  def note_exists?(directory, relative_path) do
    case vault_child(directory, relative_path) do
      {:ok, path} -> File.regular?(path)
      _ -> false
    end
  end

  @doc """
  Resolve a path inside a vault, applying both containment checks.

  Public because the contexts need it, but note the shape: it takes the vault's
  stored `directory` rather than a caller-chosen base, so there is no way to ask
  it about a path outside the root.
  """
  @spec vault_child(String.t(), String.t()) :: {:ok, String.t()} | {:error, :unsafe_path}
  def vault_child(directory, relative_path) do
    with {:ok, base} <- resolve(root(), directory) do
      resolve(base, relative_path)
    end
  end
end
