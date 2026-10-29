# Changelog

Private build. Versions are listed newest first.

## 1.0.1
- Quick Play no longer takes over the play press of a paused session from another app, such as a video or a podcast. It only starts Spotify when nothing, or Apple's Music app, owns the media session.
- Resume works on iOS 14: the tweak uses the media function iOS 14 has, keeps Spotify running long enough after a background launch to read the waiting command, and sends a resume again when Spotify drops it.
- Playing by name, Liked Songs, radio and the random picks work with Spotify 9.0 and 8.x. Their content browser differs from 9.1 in several ways, and Spotify 9.0 no longer aborts on a play request.
- The package asks for iOS 14 and builds for rootless, roothide and rootful.

## 1.0.0: first release
- Added an icon for the package and the Settings row.

## 0.19.0: renamed to Zefy Reborn
- The package is `com.goldenappleguy.zefyreborn` and replaces `com.goldenappleguy.spotifyurlplay`, which is removed when this one installs. Saved settings are copied over once.
- The command `spotifyplay` is now `zefy`, and the RemoteCompanion add-on id `spotifyplay` is now `zefy` (so `spotifyplay shuffle on` is `zefy shuffle on`). Anything that used the old names, such as RC automations or Shortcuts, needs updating.
- Notification names and files use `zefyreborn` (for example `com.goldenappleguy.zefyreborn.playstate`).
- A removal step cleans up the tweak's temporary files; the old package's leftovers are cleared on install.

## 0.18.x
- Quick Play launches Spotify clean when it is suspended in the background, which fixed audio that stopped a moment after starting. A stop-retry that fought the user's pauses was tried and removed.
- "Starting Spotify" shows in the Control Center media module until playback begins (a short form where the label is narrow, and on iOS 15 the visible label is changed directly).
- `zefy` sends requests through SpringBoard when it can, so a suspended Spotify is woken properly.

## 0.17.x
- "Starting Spotify" feedback for Quick Play.

## 0.16.x
- iOS 15: `zefy` works through SpringBoard when Spotify's data folder cannot be reached; debug relay for Spotify's log.

## 0.15.x
- Restart a playlist or album from its first track when Spotify refuses to play the one already playing.
- Faster Quick Play start (checks for a waiting request 0.25 s after launch).

## 0.14.x
- Control Center recents: Spotify's recently played items in the media module's row (up to eight).
- Every call into Spotify is guarded, so a different Spotify version logs and skips instead of crashing.

## 0.13.x
- Sleep timer held by SpringBoard. Debug commands only work with the debug flag.

## 0.12.x
- Play by name, a Now Playing file with RC triggers and a "Spotify Playing" condition.

## 0.9 to 0.11
- Random picks from recents, library and albums; Liked Songs; playlists and albums play as content items so the playlist's own tracks start.
- Loop Playlists was tried and removed (the free tier cannot be stopped from adding similar tracks).
- Spotify's app cannot read the tweak's preferences, so the Enabled setting is copied into Spotify's folder.

## 0.5 to 0.8
- RemoteCompanion add-on, like, add to and remove from a playlist, My Playlist, radio, icon Quick Actions.

## 0.1 to 0.4
- Links with a play flag start playback; `zefy` without the "Open in Spotify" prompt; Quick Play from Control Center; shuffle, repeat, skip, pause, seek, queue and navigate-only.
