# Layr8 desktop (internal)

Release packages of the Layr8 desktop app, for the team. Internal builds,
ad-hoc signed (no Developer ID), Apple silicon only.

## Before you install

- An Apple silicon Mac (arm64).
- layr8-broker 0.10.x or newer, installed, enrolled and logged in (its daemon running).
- Claude Code installed and logged in.
- gh installed and signed in to GitHub with access to this repository (`brew install gh && gh auth login`).

## Install or reinstall

Copy and run (any shell; it runs under bash):

```
bash -c 'd=$(mktemp -d) && gh release download -R layr8/layr8-desktop -p "*.zip" -D "$d" && ditto -x -k "$d"/*.zip "$d" && mkdir -p ~/Applications && rm -rf ~/Applications/Layr8.app && mv "$d/Layr8.app" ~/Applications/ && open ~/Applications/Layr8.app'
```

It downloads the latest release with gh, unpacks it, puts `Layr8.app` in
`~/Applications` and opens it. A download made by gh carries no quarantine
mark, so no right-click Open is needed. On first launch, pick your Layr8
profile; change it later from the Space name at the top left.

## Updates

The app checks this repository at start and every 30 minutes, using your gh.
When there is a newer build, the sidebar shows "Layr8 desktop internal.N —
Restart to update". Click it, and the app downloads the build, swaps itself
and reopens. It is installed in `~/Applications` because macOS may refuse
to let an app replace itself under `/Applications`.

## Known gaps

No Developer ID signature, no notarization, arm64 only, the default Electron
icon. The app's own Layr8 calls use the broker inside it.
