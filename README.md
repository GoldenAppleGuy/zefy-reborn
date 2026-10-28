# Zefy Reborn

Tweak for rootless, roothide and rootful jailbreaks (iOS 14 to 17) that makes Spotify behave like the default music player (inspired by Zefy). Formerly called SpotifyURLPlay; its command is now `zefy`. Links that carry a play flag start playback instead of only opening the page.

| Link | Effect |
|---|---|
| `https://open.spotify.com/<type>/<id>?play=true` | opens and plays |
| `https://open.spotify.com/<type>/<id>?shuffle=true` | plays and turns shuffle on |
| `spotify:<type>:<id>:play` | opens and plays |
| `spotify:<type>:<id>?play=true` | opens and plays |

`<type>` is `playlist`, `album`, `track`, `artist`, `show` or `episode`. Links without a flag behave as before.

Tested on iOS 17.0 with Spotify 9.1.94 on a free account (and on older Spotify versions, listed below): playlists, albums and tracks all start. Free accounts play playlists and albums shuffled, whatever the flag says.

`spotify:` links need an app that opens them, such as a Shortcut with the Open URLs action.

## From the terminal

```
zefy <link>             play a spotify: or open.spotify.com link
zefy -n <link>          open the page without playing
zefy -s [0|1|2]         shuffle: 0 off, 1 on (default), 2 toggle
zefy -r [0|1|2]         repeat: 0 off, 1 track (default), 2 playlist
zefy --next | --prev    skip
zefy --pause | --resume
zefy --seek <seconds>   move the position, negative goes back
zefy --queue <uri>      add a track to the queue
zefy -k [0|1|2]         like the playing track: 0 unlike, 1 like (default), 2 toggle
zefy -a <playlist>      add the playing track to a playlist
zefy -d <playlist>      remove the playing track from a playlist
zefy --setmyplaylist <playlist>
zefy --myplaylist | --addtomyplaylist | --removefrommyplaylist
zefy --radio [uri]      radio from a track, album, artist or playlist; none = the playing track
zefy --likedsongs       play Liked Songs
zefy --playlist <name>  play a playlist from your library by name (partial names work)
zefy --album <name>     play a saved album by name
zefy --artist <name>    play a followed artist by name
zefy --find <name>      best match among playlists, albums, artists and recents
zefy --status           what is playing: title - artist (album) [playing|paused] (liked)
zefy --sleep <minutes>  pause after that long; --sleep off cancels, --sleep status shows the time left
zefy --randomrecent     play a random item from your recently played
zefy --randomlibrary    play a random playlist from your library
zefy --randomalbum      play a random saved album
```

Adding to or removing from a playlist checks first and only changes what needs changing, so repeating a command is safe. The saved playlist for the `--myplaylist` options is kept in the tweak's preferences. The random picks and `--likedsongs` read the same lists Spotify shows for CarPlay (`spotify:recently-played`, `spotify:playlists`, `spotify:collection:albums`) through its content controller. Home, Daily Mixes and "made for you" are not available this way: resolving `spotify:home` fails with a Home provider error on a free account.

Run it as `mobile`. Nothing shows the "Open in Spotify" prompt, and a link works even when Spotify is not running. `uiopen --url` shows that prompt, and `uiopen --bundleid` drops the URL, which is why the command passes the request to the tweak through a file instead: `zefy` writes `zefyreborn.cmd` in Spotify's Documents folder; the tweak watches that folder, and checks once after launch.

The controls call the same playback controller Spotify uses for CarPlay. Spotify decides what an account may do: on a free account the debug log shows a refusal for shuffle off, repeat track, seek and previous, and the call has no effect.

## Settings the Spotify app can read

The Spotify app is sandboxed and cannot read the tweak's preferences, so SpringBoard and the `zefy` command copy the Enabled value into `zefyreborn.settings` in Spotify's Documents folder, which the app reads. The pane posts `com.goldenappleguy.zefyreborn.prefschanged` when the switch changes, and SpringBoard rewrites the file.

## Restarting what is already playing

Spotify refuses to play a context that is already playing (the play call returns an error). When a playlist or album request is refused, the tweak plays that context's first track as an item with its context, which is what tapping the first song does, so asking for the playing playlist or album again starts it over from the top. It retries once.

## Other Spotify versions

The Spotify-side code calls internal Spotify methods that were found in 9.1.94 (and the iPhone 15 runs it). Every such call is checked with `respondsToSelector:` first and the entry points are wrapped in `@try`, so a Spotify version that lacks or reshapes one of them logs a line and skips the feature instead of crashing the app. That was learned on Spotify 9.0.48 (iOS 15.4.1): `makeContentRequestOptions:...` is not there, and the unguarded call killed Spotify about 8 seconds after launch.

On iOS 15 the `mobile` user cannot list or write an app's data folder (Operation not permitted), so `zefy` cannot hand requests to Spotify through a file there. When it cannot find the folder, it sends the request to SpringBoard instead (through `/var/jb/tmp/zefyreborn.sbcmd`, the channel the sleep timer uses), and SpringBoard, which can write into the folder, passes it on: `relay <line>` for a command, `relay-wait <line>` for one that answers (it waits for Spotify's reply file and returns it), and `nowplaying` for the status file. On iOS 17 the command still writes the file itself. In relay mode Spotify is started in the background by SpringBoard, so a link or control does not bring Spotify to the front.

What works depends on the Spotify version. Tested: 9.1.94 on iOS 17.0 (everything), 9.0.48 on iOS 15.4.1 and 8.6.64 on iOS 14.3. On 9.0.48 the controls, status and sleep timer work, but play by name, random picks and the recents file need the content browser, which that version does not have, so they report "No match" or do nothing. Spotify 8.6.64 was checked for Quick Play and the basic controls only.

## Debug

Create an empty `zefyreborn.debug` in Spotify's Documents folder (and `/var/jb/tmp/zefyreborn.debug` for SpringBoard) to turn on the log. The `probe`, `browse`, `resolve`, `playcontent`, `playraw` and `instances` commands, and SpringBoard's `probe-classes`, `probe-class`, `probe-ivars`, `spotify-debug on|off` (creates or removes Spotify's debug flag from SpringBoard) and `spotify-log [lines]` (returns the end of Spotify's log), only work while that flag exists. The last two exist for iOS 15, where the shell cannot read Spotify's folder. They exist for researching Spotify and iOS internals and can log your library, so they stay out of normal use.

## Control Center recents

With nothing playing, the media module shows a row of recently played albums (Apple Music's). With "Control Center Recents" on (Settings > Zefy Reborn, on by default) that row shows your recently played Spotify items instead: albums first, then playlists and artists, in the order you played them, up to eight. Apple fills any empty slots.

Spotify writes its recently played list to `Documents/zefyreborn.recents` (when it launches and when the track changes), so SpringBoard can read it while Spotify is closed. The row is `MRUMediaSuggestionsController`'s `mediaSuggestions`, an array of `MRMediaSuggestion` objects built from `INPlayMediaIntent`s; each Spotify item becomes one with its Spotify URI as the identifier and `com.spotify.client` as the bundle ID, and `playSuggestion:completion:` plays it through Spotify's command file instead of the media framework. Covers come from Spotify's image servers and are kept in `/var/jb/tmp/zefyreborn-art`; an item only joins the row once its cover is on disk, because Control Center asks for artwork once when it builds the row. Liked Songs has no cover, so a heart tile is drawn. The suggestion hooks install about ten seconds after SpringBoard starts, when the MediaControls framework is loaded.

## Starting Spotify feedback

Starting Spotify from nothing takes a few seconds. After a redirected Control Center play press, the media module's placeholder text ("Not Playing") reads "Starting Spotify" and a light tap plays, until Spotify starts playing (it posts `com.goldenappleguy.zefyreborn.playstate`) or 10 seconds pass. The text is `MRUNowPlayingLabelView`'s `placeholder` on iOS 17. On iOS 15 that property is empty and the visible "Not Playing" is a plain label inside the view, so the label views are found in SpringBoard's memory when you tap play (they were created before the hook existed) and that label's text is changed directly and restored afterwards. A paused report at launch does not end the message; only "playing", a failed resume, or 10 seconds do. If no label is found, the notification `com.goldenappleguy.zefyreborn.starting` shows an RC banner instead.

## Starting playback reliably

Waking a Spotify that is suspended in the background often loses the audio a moment after it starts, while a fresh launch and a foreground resume are reliable (4 of 4 each, against about half for a suspended wake). So when a request starts playback (Quick Play, a resume, a link, play by name, random, radio, Liked Songs), nothing is playing, and Spotify is still running, SpringBoard finds its process by name, closes it, and launches it clean half a second later. A resume that Spotify refuses is retried, up to three times. (A retry for "stopped right after resuming" was tried and removed: with the clean launch it was never needed, six of six trials held without it, and it fought a pause by the user. The log still notes a stop within 0.8 s of starting.) `zefy` sends its requests through SpringBoard whenever SpringBoard answers a `ping`, because a plain file cannot wake a suspended Spotify; the file is the fallback.

## Quick Actions

Long-pressing Spotify's icon adds three items: Like Playing Track (toggle), Start Radio and My Playlist (the playlist saved with `zefy --setmyplaylist`). A tap is handled in SpringBoard, which sends the matching command to Spotify through the same command file and starts it in the background if needed; Spotify does not open. A Quick Actions switch in Settings turns the items off.

SpringBoard hooks `SBIconView applicationShortcutItems` for Spotify only, and `shouldActivateApplicationShortcutItem:atIndex:` to catch taps on its own items.

## Sleep timer

`zefy --sleep 30` pauses Spotify after 30 minutes (1 to 720). SpringBoard holds the timer, because Spotify is suspended when idle and a command may stop after a few seconds. The request goes through `/var/jb/tmp/zefyreborn.sbcmd`, which SpringBoard watches. The timer uses the wall clock: the monotonic clock stops while the phone naps. A pause is sent without launching Spotify, and a command left in Spotify's folder for more than 30 seconds is ignored at launch, so a late pause cannot fire later. A respring cancels the timer.

## Now Playing

Spotify tells the tweak about every player state change. When the track or the paused state changes, the tweak rewrites `Documents/zefyreborn.nowplaying` (which `zefy --status` reads, so it answers without waking Spotify) and posts two Darwin notifications whose state other tools can read: `com.goldenappleguy.zefyreborn.trackchanged` and `com.goldenappleguy.zefyreborn.playstate` (state 1 playing, 0 paused). A notification's state lives only while a registration for it stays open, so the tweak keeps its tokens.

Commands that answer (play by name, status) work through a reply file: the command deletes `zefyreborn.result`, writes the request, and prints the file when the tweak writes it.

## Quick Play

A play press from Control Center (or any source that sends the MediaRemote play command) with nothing playing resumes Spotify instead of going to another player. Off by default; switch it on in Settings under Zefy Reborn. An Enabled switch there turns off all of the tweak's behaviour.

SpringBoard hooks `MRMediaRemoteSendCommandToPlayerWithResult` (command 0 play, 2 toggle). If nothing is playing and Spotify is not the now-playing app, it drops the command, writes `zefyreborn:resume` to the same command file `zefy` uses, and launches Spotify in the background with FBSSystemService. Spotify finds its playback controller and calls `resumeWithCompletionHandler:`. The press can arrive on any thread, so the media state is read on the main thread with a 0.3 s timeout; if it does not answer, the press passes through.

## How it works

Spotify is scene-based, so links reach `scene:openURLContexts:`, `scene:willConnectToSession:options:` and `scene:continueUserActivity:` on its scene delegates. The tweak wraps those, and for a play link calls `playContentWithURI:withOptions:origin:loggingParams:completionHandler:` on `SPTExternalIntegrationPlaybackControllerImplementation`, the controller Spotify uses for CarPlay.

- The first argument must be an `NSURL`; Spotify bridges it to a Swift `URL`.
- Playlists, albums and artists are played as a content item through `playContent:withOptions:origin:loggingParams:completionHandler:`, the call CarPlay uses, because on a free account a bare URI can start recommended tracks instead of the playlist's own. The item is built with `SPTExternalIntegrationContentModel`, with every URL field set (a nil one traps Spotify's Swift bridging) and the item's own URI as its context.
- Spotify never creates that controller through an Objective-C `init`, and creating one yourself traps. The tweak finds the live instance by scanning the heap for the class pointer, only when a play link arrives.
- Shuffle is turned on with `enableShuffleWithCompletionHandler:` 1.5 s after playback starts.

Class and selector names come from Spotify 9.1.94 and may change in other versions.

## Debug log

Off by default. Create an empty file named `zefyreborn.debug` in Spotify's Documents folder (inside its data container); the log is `zefyreborn.log` beside it. For the SpringBoard part the flag and log are `/var/jb/tmp/zefyreborn.debug` and `/var/jb/tmp/zefyreborn.log`.

## Jailbreak types

The package comes in three builds:

- `*_iphoneos-arm64.deb`: rootless
- `*_iphoneos-arm64e.deb`: roothide (needs [roothide's Theos](https://github.com/roothide/theos), at `~/theos-roothide` or `$THEOS_ROOTHIDE`)
- `*_iphoneos-arm.deb`: rootful

The tweak finds the jailbreak's folder from where it was loaded, and the `zefy` command finds it from where it is installed. The files that start with an interpreter path (the command and the install and removal scripts) are rewritten for rootful in the Makefile. The roothide package leaves out the install and removal scripts and the RemoteCompanion add-on, which hard-code paths.

| Setup | Result |
|---|---|
| iOS 15.4.1, rootless, device | all features |
| iOS 17.0, rootless, device | all features |
| iOS 14.3, rootful, device (Spotify 8.6.64) | Quick Play with the "Starting" text, the command's play, pause, skip, shuffle, like and queue |
| roothide | builds, not run on a device |

On iOS 14 there is no `MRMediaRemoteSendCommandToPlayerWithResult`, so Quick Play hooks `MRMediaRemoteSendCommandToPlayer` instead. Spotify 8.6.64 drops a resume sent before its player has loaded, so a resume that gets no answer is sent again.

## Build

```
./build.sh
```

Builds all three packages into `packages/`. Or one at a time: `make package` (rootless), `make package THEOS=<roothide Theos> THEOS_PACKAGE_SCHEME=roothide` (roothide) or `make package THEOS_PACKAGE_SCHEME=` (rootful). Compiler overrides (`TARGET_CC` and so on) are passed through.
