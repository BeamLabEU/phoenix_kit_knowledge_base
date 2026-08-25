defmodule PhoenixKitKnowledgeBase.Migrations do
  @moduledoc """
  Versioned migration coordinator for `phoenix_kit_knowledge_base` — the module
  returned from `PhoenixKitKnowledgeBase.migration_module/0`.

  `mix phoenix_kit.update` discovers this, compares `migrated_version_runtime/1`
  (what's installed) with `current_version/0` (what the code needs), and — when
  behind — generates a host migration whose `up/0` calls `up/1` here. The host
  installs the five knowledge-base tables with no hand-written migration, and it
  honors the host's `--prefix` (named-schema installs).

  Version is tracked via a `COMMENT ON TABLE` on `phoenix_kit_kb_vaults`
  (mirroring core's own `PhoenixKit.Migrations.Postgres` and the pattern
  documented in `phoenix_kit_hello_world`'s README) rather than a boolean "does
  the table exist", so a future V2 can tell "not installed" apart from
  "installed at V1".

  ## Tables (V1)

  | Table | Holds |
  |---|---|
  | `phoenix_kit_kb_vaults` | One vault — a self-contained note space |
  | `phoenix_kit_kb_vault_members` | Per-vault membership (`owner`/`editor`/`viewer`) |
  | `phoenix_kit_kb_folders` | The folder tree inside a vault |
  | `phoenix_kit_kb_notes` | Markdown notes, tags, and the search vector |
  | `phoenix_kit_kb_note_links` | The `[[wiki-link]]` index, including unresolved links |

  Versions:

    * `0` — tables absent (not installed)
    * `1` — all five tables present, UUIDv7 primary keys
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  @initial_version 1
  @current_version 1
  @default_prefix "public"
  @version_table "phoenix_kit_kb_vaults"

  @doc "The version this code expects the schema to be at."
  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc "Run migrations up to (and including) the target version. Migration-context only."
  @spec up(keyword()) :: :ok
  def up(opts \\ []) do
    opts = with_defaults(opts, @current_version)

    case read_version(repo(), opts.escaped_prefix) do
      # Refuse rather than stamp a version onto tables we don't recognise.
      # `create_if_not_exists` cannot reshape them, so continuing would report
      # success and leave the app to crash on the first query instead.
      :incompatible ->
        raise incompatible_table_error(opts.prefix)

      0 ->
        change(@initial_version..opts.version, :up, opts)

      initial when initial < opts.version ->
        change((initial + 1)..opts.version, :up, opts)

      initial ->
        # Already stamped at or beyond the target. Re-stamp anyway: an
        # unstamped table that matched a known shape resolved to a version by
        # inspection, and this writes that conclusion down so the next read
        # doesn't have to infer it again.
        #
        # `max/2`, not `opts.version`: the table can be *ahead* of the target
        # (`up(version: 1)` against a V2 install runs no steps), and stamping
        # the target there would label a V2 schema "1".
        record_version(opts, max(initial, opts.version))
    end

    :ok
  end

  @doc "Roll back. Migration-context only."
  @spec down(keyword()) :: :ok
  def down(opts \\ []) do
    opts = with_defaults(opts, 0)
    target = Map.get(opts, :version, 0)

    # Unrecognised tables still have to be droppable — refusing here would
    # leave no way back out of the very state `up/1` rejects.
    current =
      case read_version(repo(), opts.escaped_prefix) do
        :incompatible -> @current_version
        version -> version
      end

    if current > target, do: change(current..(target + 1)//-1, :down, opts)

    :ok
  end

  @doc """
  The version currently installed in the database — 0 if the tables are absent,
  and also 0 if they exist but match no version this module knows how to
  produce. `up/1` raises with the details for that second case rather than
  migrating unrecognised tables blindly.

  Migration-context only — reads via `Ecto.Migration.repo/0`.
  """
  @spec migrated_version(keyword()) :: non_neg_integer()
  def migrated_version(opts \\ []) do
    opts = with_defaults(opts, @initial_version)
    normalize_version(read_version(repo(), opts.escaped_prefix))
  end

  @doc """
  Runtime-safe version of `migrated_version/1` — uses PhoenixKit's configured
  repo instead of the `Ecto.Migration` `repo()` helper, so it can be called
  from Mix tasks and other non-migration contexts (`mix phoenix_kit.update`).
  """
  @spec migrated_version_runtime(keyword()) :: non_neg_integer()
  def migrated_version_runtime(opts \\ []) do
    opts = with_defaults(opts, @initial_version)
    normalize_version(read_version(PhoenixKit.RepoHelper.repo(), opts.escaped_prefix))
  rescue
    _ -> 0
  end

  # ── v1 ────────────────────────────────────────────────────────────────────

  defp up_v1(prefix) do
    Helpers.ensure_uuid_v7_function(prefix)

    up_v1_vaults(prefix)
    up_v1_members(prefix)
    up_v1_folders(prefix)
    up_v1_notes(prefix)
    up_v1_links(prefix)
  end

  defp up_v1_vaults(prefix) do
    create_if_not_exists table(:phoenix_kit_kb_vaults, primary_key: false, prefix: prefix) do
      add(:uuid, :uuid,
        primary_key: true,
        null: false,
        default: fragment(Helpers.uuid_v7_call(prefix))
      )

      add(:name, :string, null: false)
      # Used in URLs (`/admin/knowledge-base/:slug`), so unique across both
      # scopes rather than per-owner.
      add(:slug, :string, null: false)
      # Where this vault's files live, relative to the configured root:
      # `system/<slug>` or `users/<email-slug>/<slug>`. Stored rather than
      # recomputed, so changing an owner's email never relocates their notes.
      add(:directory, :string, null: false)
      add(:description, :text)
      add(:icon, :string, null: false, default: "hero-book-open")
      add(:scope, :string, null: false, default: "user")
      # NULL for system vaults. No FK constraint: core's users table is
      # referenced by uuid and a deleted user must not cascade a whole vault
      # away.
      add(:owner_uuid, :binary_id)
      add(:created_by, :binary_id)
      # When this vault was last reconciled against its directory.
      add(:last_scanned_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists(unique_index(:phoenix_kit_kb_vaults, [:slug], prefix: prefix))

    # Two vaults sharing a directory would each treat the other's writes as
    # external edits and fight over the index forever.
    create_if_not_exists(unique_index(:phoenix_kit_kb_vaults, [:directory], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_kb_vaults, [:scope], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_kb_vaults, [:owner_uuid], prefix: prefix))
  end

  defp up_v1_members(prefix) do
    create_if_not_exists table(:phoenix_kit_kb_vault_members, primary_key: false, prefix: prefix) do
      add(:uuid, :uuid,
        primary_key: true,
        null: false,
        default: fragment(Helpers.uuid_v7_call(prefix))
      )

      add(
        :vault_uuid,
        references(:phoenix_kit_kb_vaults,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      # References core's users table, part of the documented public schema
      # contract. Deleting a user removes their memberships.
      add(
        :user_uuid,
        references(:phoenix_kit_users,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(:role, :string, null: false, default: "viewer")

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists(
      unique_index(:phoenix_kit_kb_vault_members, [:vault_uuid, :user_uuid], prefix: prefix)
    )

    create_if_not_exists(index(:phoenix_kit_kb_vault_members, [:user_uuid], prefix: prefix))
  end

  defp up_v1_folders(prefix) do
    # An index of the directories on disk. There is no `parent_uuid`: the
    # filesystem already expresses the hierarchy, and a second representation
    # of it in the database is a second thing that can disagree with the disk.
    # The tree is rebuilt from `relative_path` when it is needed.
    create_if_not_exists table(:phoenix_kit_kb_folders, primary_key: false, prefix: prefix) do
      add(:uuid, :uuid,
        primary_key: true,
        null: false,
        default: fragment(Helpers.uuid_v7_call(prefix))
      )

      add(
        :vault_uuid,
        references(:phoenix_kit_kb_vaults,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      # Path relative to the vault directory, e.g. `research/papers`.
      add(:relative_path, :string, null: false)
      # Trailing segment, denormalised so the sidebar needs no string work.
      add(:name, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists(
      unique_index(:phoenix_kit_kb_folders, [:vault_uuid, :relative_path], prefix: prefix)
    )
  end

  defp up_v1_notes(prefix) do
    create_if_not_exists table(:phoenix_kit_kb_notes, primary_key: false, prefix: prefix) do
      add(:uuid, :uuid,
        primary_key: true,
        null: false,
        default: fragment(Helpers.uuid_v7_call(prefix))
      )

      add(
        :vault_uuid,
        references(:phoenix_kit_kb_vaults,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      # The note's identity: its path relative to the vault directory. The
      # filesystem guarantees this is unique, which is why the unique index is
      # here and not on the title — two folders may each hold an `Ideas.md`,
      # and the index must be able to describe what is actually on disk rather
      # than reject it.
      add(:relative_path, :string, null: false)
      # Directory part, `""` at the vault root. Denormalised from
      # `relative_path` so folder filtering is an index lookup.
      add(:folder_path, :string, null: false, default: "")

      # Filename without `.md`. Not unique — see above.
      add(:title, :string, null: false)
      # Normalised title. What `[[wiki-links]]` match on, so it is indexed but
      # may legitimately collide; resolution breaks ties by path.
      add(:title_key, :string, null: false)

      # A cache of the file's bytes, kept so search and rendering do not touch
      # the disk. The file is authoritative; this column is rebuilt from it.
      add(:content, :text, null: false, default: "")
      add(:frontmatter, :map, null: false, default: %{})
      add(:tags, {:array, :string}, null: false, default: [])

      # Change detection. `file_mtime` and `file_size` are the cheap first pass
      # during a rescan; `content_hash` is the authority, and is also what the
      # stale-write guard compares before overwriting a file, and what makes an
      # external `mv` recognisable as a rename rather than a delete plus create.
      add(:content_hash, :string)
      add(:file_mtime, :utc_datetime_usec)
      add(:file_size, :bigint)

      add(:created_by, :binary_id)
      add(:updated_by, :binary_id)

      timestamps(type: :utc_datetime_usec)
    end

    # Generated column, so the search index can never drift from the cached
    # content: Postgres recomputes it on every write. Title outranks body via
    # setweight, which is what puts an exact-title hit first.
    execute(
      """
      ALTER TABLE #{Helpers.qualify_table("phoenix_kit_kb_notes", prefix)}
      ADD COLUMN IF NOT EXISTS search_vector tsvector
      GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(content, '')), 'B')
      ) STORED
      """,
      """
      ALTER TABLE #{Helpers.qualify_table("phoenix_kit_kb_notes", prefix)}
      DROP COLUMN IF EXISTS search_vector
      """
    )

    create_if_not_exists(
      unique_index(:phoenix_kit_kb_notes, [:vault_uuid, :relative_path], prefix: prefix)
    )

    create_if_not_exists(index(:phoenix_kit_kb_notes, [:vault_uuid, :title_key], prefix: prefix))

    create_if_not_exists(
      index(:phoenix_kit_kb_notes, [:vault_uuid, :folder_path], prefix: prefix)
    )

    # Rename detection during a rescan: find the note that used to hold this
    # content, wherever it was.
    create_if_not_exists(
      index(:phoenix_kit_kb_notes, [:vault_uuid, :content_hash], prefix: prefix)
    )

    create_if_not_exists(
      index(:phoenix_kit_kb_notes, [:tags],
        using: "GIN",
        name: :phoenix_kit_kb_notes_tags_index,
        prefix: prefix
      )
    )

    create_if_not_exists(
      index(:phoenix_kit_kb_notes, [:search_vector],
        using: "GIN",
        name: :phoenix_kit_kb_notes_search_index,
        prefix: prefix
      )
    )
  end

  defp up_v1_links(prefix) do
    create_if_not_exists table(:phoenix_kit_kb_note_links, primary_key: false, prefix: prefix) do
      add(:uuid, :uuid,
        primary_key: true,
        null: false,
        default: fragment(Helpers.uuid_v7_call(prefix))
      )

      add(
        :vault_uuid,
        references(:phoenix_kit_kb_vaults,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(
        :source_note_uuid,
        references(:phoenix_kit_kb_notes,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      # NULL = an unresolved link: the target note does not exist (yet). Stored
      # as a real row rather than an absence, because "what have I linked to
      # but not written?" is the question that grows a vault. `nilify_all`
      # turns a link back into an unresolved one when its target is deleted,
      # instead of silently dropping the mention.
      add(
        :target_note_uuid,
        references(:phoenix_kit_kb_notes,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: prefix
        )
      )

      # Normalised target. A bare title (`ideas`) or, when the link was written
      # path-qualified to disambiguate, a normalised path (`research/ideas`).
      add(:target_key, :string, null: false)
      # The target exactly as written inside `[[...]]`, for display.
      add(:target_title, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    # One row per (source, target) pair — writing `[[Foo]]` five times in a
    # note is one link, not five.
    create_if_not_exists(
      unique_index(:phoenix_kit_kb_note_links, [:source_note_uuid, :target_key], prefix: prefix)
    )

    # Backlinks panel.
    create_if_not_exists(index(:phoenix_kit_kb_note_links, [:target_note_uuid], prefix: prefix))

    # Resolving unresolved links when a matching note appears.
    create_if_not_exists(
      index(:phoenix_kit_kb_note_links, [:vault_uuid, :target_key], prefix: prefix)
    )
  end

  defp down_v1(prefix) do
    # Reverse dependency order. The FK cascades would handle it, but being
    # explicit keeps the rollback readable and prefix-correct.
    drop_if_exists(table(:phoenix_kit_kb_note_links, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_kb_notes, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_kb_folders, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_kb_vault_members, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_kb_vaults, prefix: prefix))
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp change(range, direction, opts) do
    Enum.each(range, fn
      1 -> apply_step(direction, opts.prefix)
    end)

    case direction do
      :up -> record_version(opts, Enum.max(range))
      :down -> record_version(opts, max(Enum.min(range) - 1, 0))
    end
  end

  defp apply_step(:up, prefix), do: up_v1(prefix)
  defp apply_step(:down, prefix), do: down_v1(prefix)

  defp record_version(_opts, 0), do: :ok

  defp record_version(%{prefix: prefix}, version) do
    execute("COMMENT ON TABLE #{Helpers.qualify_table(@version_table, prefix)} IS '#{version}'")
  end

  defp with_defaults(opts, version) do
    opts = Enum.into(opts, %{prefix: @default_prefix, version: version})

    opts
    |> Map.put(:quoted_prefix, inspect(opts.prefix))
    |> Map.put(:escaped_prefix, String.replace(opts.prefix, "'", "\\'"))
  end

  # `:incompatible` reported to callers that must return a plain integer.
  # Reporting 0 ("not installed") is right for them: `mix phoenix_kit.update`
  # then generates a migration, and running it surfaces the real problem
  # through `up/1`'s raise, with instructions.
  defp normalize_version(:incompatible), do: 0
  defp normalize_version(version) when is_integer(version), do: version

  # The installed version, or `:incompatible` when the tables exist but match no
  # version this module knows how to produce.
  #
  # The `COMMENT ON TABLE` marker is the source of truth, but it can be missing:
  # restored from a dump that dropped comments, say. An unstamped table is then
  # resolved by looking at its actual columns, so the answer is derived rather
  # than assumed. Guessing `1` there would assert "already current" about a
  # table nobody checked; guessing `0` is just as wrong, because
  # `create_if_not_exists` would skip the existing table and the stamp would go
  # on regardless — marking a wrong-shaped table as correct.
  defp read_version(repo, escaped_prefix) do
    if table_exists?(repo, escaped_prefix, @version_table) do
      case stamped_version(repo, escaped_prefix) do
        {:ok, version} -> version
        :unstamped -> infer_version(repo, escaped_prefix)
      end
    else
      0
    end
  end

  defp table_exists?(repo, escaped_prefix, table) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = '#{table}'
      AND table_schema = '#{escaped_prefix}'
    )
    """

    match?({:ok, %{rows: [[true]]}}, repo.query(query, [], log: false))
  end

  defp stamped_version(repo, escaped_prefix) do
    query = """
    SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
    FROM pg_class
    LEFT JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
    WHERE pg_class.relname = '#{@version_table}'
    AND pg_namespace.nspname = '#{escaped_prefix}'
    """

    case repo.query(query, [], log: false) do
      {:ok, %{rows: [[comment]]}} -> parse_version_comment(comment)
      _ -> :unstamped
    end
  end

  @doc false
  # A comment that isn't a bare integer is somebody else's annotation, not our
  # marker — treated as unstamped rather than crashing on `String.to_integer/1`.
  def parse_version_comment(comment) when is_binary(comment) do
    case Integer.parse(String.trim(comment)) do
      {version, ""} when version >= 0 -> {:ok, version}
      _ -> :unstamped
    end
  end

  def parse_version_comment(_), do: :unstamped

  # Match the schema against the shape of each known version, newest first. V1
  # is identified by `notes.relative_path` — the column that distinguishes the
  # filesystem-backed schema from the database-only shape that preceded it.
  defp infer_version(repo, escaped_prefix) do
    if table_exists?(repo, escaped_prefix, "phoenix_kit_kb_notes") and
         column_exists?(repo, escaped_prefix, "phoenix_kit_kb_notes", "relative_path"),
       do: 1,
       else: :incompatible
  end

  defp column_exists?(repo, escaped_prefix, table, column) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.columns
      WHERE table_name = '#{table}'
      AND table_schema = '#{escaped_prefix}'
      AND column_name = '#{column}'
    )
    """

    match?({:ok, %{rows: [[true]]}}, repo.query(query, [], log: false))
  end

  defp incompatible_table_error(prefix) do
    """
    phoenix_kit_kb_vaults exists in schema "#{prefix}" but the knowledge base \
    schema does not match any known version of this module, and carries no \
    version comment.

    Most likely an interrupted first install left some tables created and \
    others not. Migrating in place is not attempted because the existing \
    tables may hold data only you can judge.

    To inspect what is there:

        \\dt #{prefix}.phoenix_kit_kb_*

    If the tables are empty, drop them and re-run the migration:

        DROP TABLE IF EXISTS #{prefix}.phoenix_kit_kb_note_links,
                             #{prefix}.phoenix_kit_kb_notes,
                             #{prefix}.phoenix_kit_kb_folders,
                             #{prefix}.phoenix_kit_kb_vault_members,
                             #{prefix}.phoenix_kit_kb_vaults CASCADE;

    If they hold notes you need, back them up first:

        CREATE TABLE phoenix_kit_kb_notes_backup AS
          SELECT * FROM #{prefix}.phoenix_kit_kb_notes;
    """
  end
end
