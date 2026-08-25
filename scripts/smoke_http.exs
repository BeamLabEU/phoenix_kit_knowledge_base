# Renders every knowledge base page as a logged-in user and fails on any that
# 500s or shows an exception page.
#
# This exists because of a bug it would have caught. Every check up to that
# point fetched pages with plain `curl`, which is never authenticated, so the
# admin routes always answered 302 and no template was ever executed — a
# `BadBooleanError` in the sidebar rendered fine in every test and crashed in
# the browser. Template-level mistakes are invisible to `mix test` here (the
# suite is deliberately database-free and has no endpoint) and invisible to an
# unauthenticated request. This closes that gap.
#
# Run from the HOST app, not this repo:
#
#     cd /www/app
#     APP_PID=$(pgrep -f "mix phx.server" | head -1) \
#       mix run --no-start ../phoenix_kit_knowledge_base/scripts/smoke_http.exs
#
# It forges a session cookie from the running server's SECRET_KEY_BASE, so the
# server must be up. Host-specific bits are below — adjust for another app.
# Lowercase deliberately: an uppercase name in Elixir is an alias, not a
# constant, and `REPO = DmitriDon.Repo` is a failing match against `Elixir.REPO`.
repo = DmitriDon.Repo
session_key = "_dmitri_don_key"
signing_salt = "FyUIJDAN"
base_url = "http://localhost:4000"

{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:req)
# PhoenixKit broadcasts a session-created event; without its PubSub running,
# minting a token dies on an unknown registry.
{:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: :phoenix_kit_internal_pubsub)
{:ok, _} = repo.start_link(pool_size: 2)

import Ecto.Query
alias PhoenixKitKnowledgeBase.{Notes, Storage, Vaults}
alias PhoenixKitKnowledgeBase.Schemas.Vault

secret =
  "/proc/#{System.get_env("APP_PID")}/environ"
  |> File.read!()
  |> String.split(<<0>>)
  |> Enum.find_value(fn kv ->
    case String.split(kv, "=", parts: 2) do
      ["SECRET_KEY_BASE", v] -> v
      _ -> nil
    end
  end)

user = repo.one(from u in PhoenixKit.Users.Auth.User, limit: 1)
token = PhoenixKit.Users.Auth.generate_user_session_token(user)

# Same construction Plug.Session's cookie store uses.
key = Plug.Crypto.KeyGenerator.generate(secret, signing_salt)
cookie =
  %{"user_token" => token}
  |> :erlang.term_to_binary()
  |> then(&Plug.Crypto.MessageVerifier.sign(&1, key))

scope = %PhoenixKit.Users.Auth.Scope{user: %{uuid: user.uuid, email: user.email}}
repo.delete_all(from v in Vault, where: v.slug == "smoke")
File.rm_rf(Path.join(Storage.root(), "users/#{Storage.email_slug(user.email)}/smoke"))
{:ok, vault} = Vaults.create(%{"name" => "Smoke", "slug" => "smoke"}, scope, :user)
{:ok, note} = Notes.create_note(vault, %{"title" => "Hello", "content" => "Links to [[Nowhere]]"}, user.uuid)
{:ok, trashed} = Notes.create_note(vault, %{"title" => "Trashed", "content" => "x"}, user.uuid)
{:ok, _} = Notes.delete_note(vault, trashed)

check = fn label, path, expect ->
  result =
    try do
      Req.get(base_url <> path,
        headers: [cookie: session_key <> "=#{cookie}"], redirect: false, retry: false)
    rescue
      error -> {:error, error}
    end

  {resp, transport_error} =
    case result do
      {:ok, resp} -> {resp, nil}
      {:error, error} -> {%{status: 0, body: ""}, Exception.message(error)}
    end

  body = to_string(resp.body)

  problem =
    transport_error ||
    cond do
      resp.status >= 500 -> "HTTP #{resp.status}"
      expect == :redirect and resp.status in 300..399 -> nil
      expect == :redirect -> "expected a redirect, got #{resp.status}"
      resp.status in 300..399 -> "redirected — session rejected?"
      String.contains?(body, "Exception:") -> "exception page"
      String.contains?(body, "BadBooleanError") -> "BadBooleanError"
      true -> nil
    end

  IO.puts("#{if problem, do: "FAIL", else: "ok  "}  #{label} → #{resp.status}#{if problem, do: "  (#{problem})", else: ""}")
  problem == nil
end

results = [
  check.("vault list", "/en/admin/knowledge-base", :ok),
  check.("vault workspace", "/en/admin/knowledge-base/smoke", :ok),
  check.("open note", "/en/admin/knowledge-base/smoke/notes/#{note.uuid}", :ok),
  check.("new note from dangling link", "/en/admin/knowledge-base/smoke/notes/new?title=Nowhere", :ok),
  check.("members", "/en/admin/knowledge-base/smoke/members", :ok),
  check.("unknown vault redirects away", "/en/admin/knowledge-base/does-not-exist", :redirect)
]

repo.delete_all(from v in Vault, where: v.slug == "smoke")
File.rm_rf(Path.join(Storage.root(), "users/#{Storage.email_slug(user.email)}/smoke"))

IO.puts(if Enum.all?(results), do: "\nALL PAGES RENDER", else: "\nSOME PAGES FAILED")
