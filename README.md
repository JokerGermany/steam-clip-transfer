# steam-clip-transfer

Move Steam game recordings from a Steam Deck (SteamOS) to a home server, with the
**Deck notifying the server and the server pulling the files itself**.
No polling on the server side, no NFS mount on the Deck, and both SSH keys are
restricted to the bare minimum.

```
Deck: clip-mover.sh ──ssh (key A, forced command only)──▶ Server: clip-pull.sh
                                                             │
Deck: sshd + rrsync -ro  ◀──rsync (key B, read-only)─────────┘
Deck deletes the source only after the server exits with 0
```

## Features

- Watches **all** `~/.local/share/Steam/userdata/<userid>/gamerecordings/video`
  directories (multiple Steam accounts supported).
- Waits until a recording folder stops growing before touching it.
- Writes the **game name** into the folder as `game_name.txt` before handing it
  over. Steam games are resolved from `appmanifest_*.acf`, non-Steam games from
  `shortcuts.vdf`, which only exists on the Deck.
- Server copies into a hidden temp folder and renames atomically, so other
  tools watching the destination never see half-copied folders.
- Interrupted transfers resume (`rsync --partial`).
- Works offline: if the server is unreachable, one log line is written and
  recordings stay on the Deck until the next successful run.
- Runs as a systemd **user** service and starts with SteamOS.
- No extra packages on SteamOS. `python3` (for game names) and `inotifywait`
  (faster reaction) are used if present.

## Security model

| Key | Direction | What it can do |
|-----|-----------|----------------|
| A (`clip_notify`) | Deck → Server | Run `clip-pull.sh` with one strictly validated relative path. No shell, no PTY, no forwarding (`restrict,command=…`). |
| B (`clip_pull`) | Server → Deck | Read-only rsync below `Steam/userdata` via `rrsync -ro`, optionally limited by `from=`. No write, no delete, no shell. |

The guarantees for key B only hold with the `rrsync` setup. See *Insecure variant* below.

- The server account (`clipsync`) has no sudo and only write access to the
  destination directory.
- The Deck deletes its own files. The server never needs write access to the Deck.
- The server pulls from the IP the notification came from. The Deck's host key
  is pinned via `HostKeyAlias=steamos`, so a foreign host at the same IP is
  rejected.

## Files

| File | Runs on | Purpose |
|------|---------|---------|
| `clip-mover.sh` | Deck | Watches recordings, writes `game_name.txt`, notifies server, deletes on success |
| `clip-mover.service` | Deck | systemd user unit |
| `clip-pull.sh` | Server | Forced SSH command: validates path, pulls, renames atomically |
| `mpdToMP4.sh` | Server | Optional: converts the recordings to MP4 and uses `game_name.txt` for per-game folders |
| `crop.sh` | Server | Black-border detection, sourced by `mpdToMP4.sh` (must be in the same directory); can also be run standalone |

## Installation

### Server

```bash
sudo useradd -m -s /bin/bash clipsync     # a shell is required to run the forced command
sudo install -m 755 clip-pull.sh /usr/local/bin/clip-pull.sh
sudo install -d -o clipsync /path/to/destination
sudo -u clipsync ssh-keygen -t ed25519 -N '' -f ~clipsync/.ssh/clip_pull     # key B
```

Set `CLIP_PULL_DEST` (and optionally `CLIP_PULL_DECK_USER`) in the script or
environment.

`~clipsync/.ssh/authorized_keys` (key A from the Deck, one line):

```
restrict,command="/usr/local/bin/clip-pull.sh" ssh-ed25519 AAAA... deck-notify
```

Pin the Deck's host key once (any current IP):

```bash
sudo -u clipsync ssh -o HostKeyAlias=steamos -i ~clipsync/.ssh/clip_pull <deck-user>@<deck-ip> true
```

### Steam Deck

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/clip_notify     # key A
passwd                                                # if no password is set yet
sudo systemctl enable --now sshd
```

Locate `rrsync`:

```bash
ls /usr/bin/rrsync /usr/lib/rsync/rrsync 2>/dev/null
```

If it is missing, place `rrsync` (a Python script shipped with the rsync
sources since 3.2.4) in `~/bin/rrsync` and adjust the path below.

`~/.ssh/authorized_keys` on the Deck (key B from the server, one line):

```
restrict,from="<server-ip>",command="/usr/bin/rrsync -ro /home/<deck-user>/.local/share/Steam/userdata" ssh-ed25519 AAAA... clip-pull
```

With `rrsync`, set `CLIP_PULL_REMOTE_BASE=""` in `clip-pull.sh`, because
`rrsync` already starts in `Steam/userdata`.

#### Insecure variant: no restrictions on the Deck

If you do not want to touch `authorized_keys` options on the Deck, add key B
as a plain line:

```
ssh-ed25519 AAAA... clip-pull
```

and leave `CLIP_PULL_REMOTE_BASE` at its default
(`.local/share/Steam/userdata`, relative to the Deck user's home).

> **Warning:** Key B then grants a **full shell** on the Deck. Anyone who
> controls the `clipsync` account on the server can read, modify and delete
> anything the Deck user can, and run `sudo` if no password is required.
> The read-only guarantee and the `from=` restriction from the security model
> above **no longer apply**. The server becomes a single point of compromise
> for every Deck. Only use this in a trusted network, and prefer the `rrsync`
> variant.

Disable password login, e.g. `/etc/ssh/sshd_config.d/10-keyonly.conf`:

```
PasswordAuthentication no
KbdInteractiveAuthentication no
```

`~/.config/clip-mover.conf`:

```bash
NOTIFY_TARGET=clipsync@<server>
```

Install and start the service:

```bash
mkdir -p ~/bin ~/.config/systemd/user
install -m 755 clip-mover.sh ~/bin/
cp clip-mover.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now clip-mover.service
sudo loginctl enable-linger "$USER"     # optional: run without an active session
```

## Configuration

`clip-mover.sh` reads `~/.config/clip-mover.conf` (plain shell variables) or
`CLIP_MOVER_*` environment variables.

| Variable | Default | Meaning |
|----------|---------|---------|
| `NOTIFY_TARGET` | `clipsync@server` | Server account with the forced command |
| `NOTIFY_KEY` | `~/.ssh/clip_notify` | Key A |
| `DEVICE_USER` | output of `id -un` | User name on this device, sent to the server so it pulls as the right user (`deck` on Steam Deck, `steamos` on Steam Frame) |
| `STEAM_USERDATA` | `~/.local/share/Steam/userdata` | Steam userdata root |
| `WATCH_SUBPATH` | `gamerecordings/video` | Watched path below each user ID |
| `STEAM_ROOT` | `~/.local/share/Steam` | Used to resolve game names |
| `GAME_NAME_FILE` | `game_name.txt` | Name of the game name file |
| `POLL_INTERVAL` | `60` | Seconds between scans |
| `STABLE_CHECKS` / `STABLE_INTERVAL` | `2` / `10` | Folder must be unchanged for N checks, every N seconds |
| `NOTIFY_ATTEMPTS` / `NOTIFY_RETRY_DELAY` | `3` / `30` | Retries if the server reports an error |
| `LOG_FILE` | `~/clip-mover.log` | Log file (also visible via `journalctl --user -u clip-mover`) |

`clip-pull.sh` uses `CLIP_PULL_REMOTE_BASE` (path to `Steam/userdata` relative
to the Deck user's home; default `.local/share/Steam/userdata`, set to `""`
when using `rrsync`), `CLIP_PULL_HOSTKEY_ALIAS` (default `steamos`, one alias
for the host keys of all devices), `CLIP_PULL_DEST`, `CLIP_PULL_KEY`, `CLIP_PULL_DECK_USER` (fallback if the device sends no user name),
`CLIP_PULL_DECK_HOST` (empty = IP of the connecting Deck), `CLIP_PULL_LOG_FILE`
and `CLIP_PULL_LOCK`.

### Game name in `mpdToMP4.sh`

In `-gamefolder` mode the folder name is chosen in this order:

1. `appid_names.conf` (manual mapping)
2. `game_name.txt` supplied by the Deck
3. Local lookup on the server (`appmanifest_*.acf`, `shortcuts.vdf`)

## Testing

```bash
# On the Deck: manual notification
ssh -i ~/.ssh/clip_notify clipsync@<server> '<userid>/gamerecordings/video/<folder>'; echo $?
# Expected: 0 and the folder is on the server.
# Without an argument, or with anything else, the call must be rejected.
```

## Known limitations

- Recordings in `gamerecordings/video` are Steam's background recordings.
  Once moved, they are presumably no longer shown in Steam's own recording
  timeline. Try with a test recording first.
- Requires `sshd` to be running on the Deck.
- Whether `rrsync` ships with SteamOS and whether changes below `/etc/ssh`
  survive SteamOS updates has not been verified. Check after updates.
- Folders with the same name from different Steam accounts are merged on the
  server.

## License

Copyright (C) 2026 JokerGermany

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. See the [LICENSE](LICENSE) file for details.
