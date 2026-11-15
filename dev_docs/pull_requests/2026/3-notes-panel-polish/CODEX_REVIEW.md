# Codex review — PR #3

Reviewed on 2026-11-15 as part of the weekly release recheck, including the
follow-up fixes through `1a86ff8`. Full findings, fixes and verification are in
[`2026-11-15-codex-pre-release-recheck.md`](../../../reviews/2026-11-15-codex-pre-release-recheck.md).

The panel's tree, drag destinations and note mutations retain the earlier
reviews' fence and stale-location fixes. This pass additionally fixes context
reuse: a host changing the panel's path or user now releases the previous
editor, and removing its selected visibility switches to an allowed option.
Cosmetic host updates preserve the editor's original stale-write hash.

The same pass fixes remaining stale-hash adoption and live membership
revocation on the admin vault page. Validation: 381 tests pass, including
Postgres integration, and `mix precommit`, the docs build and Hex package build
pass. Host HTTP smoke tests and Leaf browser checks remain outstanding because
the documented `/www/app` host is unavailable here.
