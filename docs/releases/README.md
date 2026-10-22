# Release descriptions

Before tagging a release, add `vMAJOR.MINOR.PATCH.md` here. The first line must
be `# vMAJOR.MINOR.PATCH · Short descriptive title`; the remaining Markdown is
the complete release body. Use `v0.15.0.md` as an example: concrete user-visible
changes, the UI entry point, a platform download table, upgrade notes and one
changelog link. Keep CLI/MCP downloads in a collapsed section.

Validate locally with:

```sh
python packaging/update_release_notes.py --check
```

The tagged Build workflow validates the matching document before building. Each
platform uploads assets without generating notes. After all three builds finish,
one job replaces the release title and body from the document.

To correct a published description, edit its Markdown file and push to `main`.
The **Update release notes** workflow updates existing releases automatically;
it can also be run manually. Missing releases are skipped during bulk sync, so
adding notes for an upcoming version does not publish it early. A tag-specific
update requires that release to exist. Repeated runs replace the same title/body
instead of appending duplicate text. Tags, release visibility and assets are not
modified by this workflow. Authentication uses the workflow's built-in token.
