defmodule PhoenixKitKnowledgeBase.Errors do
  @moduledoc """
  The one place an error reason becomes a sentence a person reads.

  Contexts return atoms and tuples (`{:error, :stale}`, `{:error,
  {:forbidden_characters, ["#"]}}`); the LiveViews call `message/1` at the
  flash boundary. Keeping the copy here means the vault page and the notes
  panel say the same thing about the same failure, and translators have one
  file to work from.

  A reason nothing here knows is **logged, not shown**: an `inspect/1`-ed term
  in a flash tells the person nothing and the developer less than the log line
  does.
  """

  use Gettext, backend: PhoenixKitKnowledgeBase.Gettext

  require Logger

  alias PhoenixKitKnowledgeBase.Storage
  alias PhoenixKitWeb.Components.Core.Input

  @doc "A translated, user-facing sentence for an error reason."
  @spec message(term()) :: String.t()
  def message(:unauthorized), do: gettext("You do not have permission to do that.")

  def message(:stale),
    do:
      gettext(
        "This note changed on disk since you opened it. Reload to see that version, or overwrite it with yours."
      )

  def message(:missing_file),
    do:
      gettext(
        "This note's file is gone from disk — moved or deleted somewhere else. Reload, or overwrite to write your version back."
      )

  def message({:forbidden_characters, chars}) do
    gettext(
      "A name cannot contain %{characters} — they break either the filesystem or [[link]] syntax. Not allowed: %{all}",
      characters: Enum.join(chars, " "),
      all: Storage.forbidden_characters()
    )
  end

  def message(:blank), do: gettext("A name cannot be empty.")

  def message(:leading_dot),
    do: gettext("A name cannot start with a dot — that would hide the file.")

  def message(:trailing_dot), do: gettext("A name cannot end with a dot.")
  def message(:too_long), do: gettext("That name is too long for a file name.")

  def message(:reserved),
    do: gettext("That name is reserved by Windows and would break syncing the vault there.")

  def message(:already_exists),
    do: gettext("A note with that name already exists in this folder.")

  def message(:target_exists), do: gettext("Something with that name is already there.")
  def message(:too_many_duplicates), do: gettext("Too many notes already have that name.")
  def message(:unsafe_path), do: gettext("That path is not inside the vault.")
  def message(:refuse_descendant), do: gettext("A folder cannot be moved inside itself.")

  def message(:refuse_vault_root),
    do: gettext("The vault's own folder cannot be moved or deleted.")

  def message(:not_found), do: gettext("That no longer exists.")
  def message(:not_in_trash), do: gettext("That is not in the trash.")

  def message(:not_text),
    do:
      gettext(
        "This text contains a character a note cannot hold (a NUL byte). Remove it and save again."
      )

  def message(:enoent), do: gettext("That file no longer exists on disk.")
  def message(:eacces), do: gettext("The server is not allowed to write to the vault's folder.")
  def message(:enospc), do: gettext("The disk holding the vault is full.")
  def message(:erofs), do: gettext("The vault's folder is read-only.")
  def message({:folder, reason}), do: message(reason)

  def message({:reindex_incomplete, paths}) when is_list(paths) do
    ngettext(
      "The folder moved, but %{count} note in it could not be re-indexed. Rescan the vault to repair it.",
      "The folder moved, but %{count} notes in it could not be re-indexed. Rescan the vault to repair it.",
      length(paths)
    )
  end

  def message(%Ecto.Changeset{} = changeset), do: changeset_message(changeset)

  def message(other) do
    Logger.warning("[knowledge_base] no message for error #{for_log(other)}")
    gettext("Something went wrong. Try again, or rescan the vault.")
  end

  @doc """
  An error reason, fit for a log line.

  A changeset is reduced to its messages: it carries the note's whole content,
  which has no business in a log. Anything else is inspected, bounded.
  """
  @spec for_log(term()) :: String.t()
  def for_log(%Ecto.Changeset{} = changeset), do: changeset_message(changeset)
  def for_log({:error, reason}), do: for_log(reason)
  def for_log(reason), do: inspect(reason, limit: 10, printable_limit: 200)

  @doc """
  Every error on a changeset, as one sentence.

  Messages go through core's error translation — the same one `<.input>`
  uses — so Ecto's own ("can't be blank") read the same here as on a form.
  """
  @spec changeset_message(Ecto.Changeset.t()) :: String.t()
  def changeset_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&Input.translate_error/1)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end
end
