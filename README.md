# ATMusic for Roku

A BrightScript / SceneGraph channel for [ATMusic](https://atmusic.atdevs.org) - browse, play and share music on your TV.
Licensed under the **GNU GPL v3** (see `LICENSE`).

> Status: development build (v0.4.7). It is a sideloadable developer channel, not yet on the Roku Channel Store.

## Features

- **Browse:** New, For You, Trending, Search, Albums, Creators, Tags, Playlists, Discover (public playlists), Favorites,
  Library (genres, moods, artists, recently added / most played / recently played, **Collections**), Info (stats, status, changelog, credits).
- **Play:** queue-based playback with a mini player and a Now Playing screen: like, dislike, favorite, add to playlist, lyrics.
- **Sign in without typing a password:** *Log in with phone (QR)* - scan a code with a phone that is already signed in and approve.
  Password sign-in is also supported (including a TOTP / recovery-code step for accounts with MFA). The session is kept in the Roku registry.
- **ATMusic Sync:** join a session by code (the TV follows the leader's track and position with drift correction), or start one.
- **ATCLAM visualizer:** an ATCLAM bytecode virtual machine written in BrightScript (`components/AtclamVm.brs`) runs the same
  bytecode as ATMusic's web and Rust runtimes. It runs the built-in visualizers, published creator scripts (with imported libraries linked),
  and the *ATCLAM demo-everything* collection. Roku has no live audio analysis, so a script's audio inputs are derived from the server's
  analysis of the playing track.
- **Client debug logging** (on by default, toggle in *Info > Debug logging*): diagnostic events (never passwords, tokens or cookies) are sent
  in batches to ATMusic's `/api/debug/logs` endpoint while you are signed in. It counts toward your account storage and can be cleared there.

## Layout

```
manifest               channel metadata and version
source/main.brs        entry point + global setup (debug flag, launch parameters)
components/            MainScene (service gating), AppShell (UI + logic), NetworkTask, TrackRow,
                       AtclamVm / AtclamTask (ATCLAM runtime), DebugLog / DebugTask (client debug logging)
data/                  bundled ATCLAM visualizers, demo scripts and the conformance suite
images/                channel art
```

## Sideload

1. Put your Roku in developer mode (Home x3, Up x2, Right, Left, Right, Left, Right) and note its IP address and the installer password you set.
2. Zip the contents of this repository (the `manifest` file must be at the top level of the zip, not inside a folder).
3. Open `http://<roku-ip>` in a browser, sign in, and upload the zip.

The channel's log is available with `nc <roku-ip> 8085` (everything it logs is prefixed `[atm]`).

## ATCLAM conformance

`data/atclam-conformance.json` is a suite of compiled test programs with the exact outcome of the reference Rust VM for each
(host calls, storage operations, cancel flag, instruction count, or error kind). To run it on the device, launch the channel with a parameter:

```
curl -d '' "http://<roku-ip>:8060/launch/dev?atclam=test"
```

and read the `[atm] atclam result` line on the console (the current build passes all 38 cases). Firmware quirks the VM works around
(32-bit JSON numbers, division by zero throwing, case-insensitive dictionary keys, ...) are documented at the top of `components/AtclamVm.brs`.

## Known limitations

- ATCLAM scripts that declare `runtime { server }` are not supported on the Roku.
- Scripts are read as ASCII (no non-ASCII characters in string literals) and call depth is capped at 64.
- Triangles are drawn as stacked horizontal strips because Roku has no polygon node.
- Not on the Channel Store; the update check still uses the legacy `roku/spool` service id.
