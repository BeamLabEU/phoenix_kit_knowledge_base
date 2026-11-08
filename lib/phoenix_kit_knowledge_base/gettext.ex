defmodule PhoenixKitKnowledgeBase.Gettext do
  @moduledoc """
  Gettext backend for the knowledge base's own translations.

  The host sets the locale per request; this module only owns the catalogues
  under `priv/gettext/`:

    * `default` — this module's strings (the notes panel, the sidebar tab)
    * `leaf` — the Leaf editor's strings, for the editor inside the notes
      panel. Leaf looks its strings up in the `"leaf"` domain of whatever
      backend it is given, and the panel gives it this one, so a host gets a
      translated toolbar without adding Leaf's catalogue to its own.

  Shipped: Russian (`ru`) and Estonian (`et`); English is the source.
  """
  use Gettext.Backend, otp_app: :phoenix_kit_knowledge_base

  # The plural-form code `use Gettext.Backend` generates hands Expo's opaque
  # `PluralForms` to `Gettext.Plural.plural/2`, which dialyzer flags. It is the
  # library's code and the library's types; this module has nothing else in it.
  @dialyzer :no_opaque
end
