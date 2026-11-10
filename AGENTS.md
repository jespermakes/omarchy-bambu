# AGENTS.md

You are probably here because someone's printer or network does something this plugin
did not expect, and they asked you to fix it. Good. This file is the briefing: how the
pieces fit, how to test without ruining a print, and the traps already found.

## The one rule

**A real person's print may be running.** Never send `stop`, `pause`, `speed` or raw
commands to "see if it works" unless the user says the printer is idle or tells you to.
`bambu status`, `bambu doctor` and `bambu snapshot` are safe at any time. `doctor` does
send one command: it sets the chamber light to the mode it already has, to learn whether
Developer Mode is on. That is the only command it sends.

## Start here

```
bambu doctor            # network, status, controls, camera, one line each
bambu status --json     # {"ok": ..., "printers": [...]}, always that shape
bambu watch             # live, Ctrl-C to stop
```

`doctor` tells you which layer is broken. Fix that layer, then run it again.
If `bambu` is not on PATH it lives at `~/.config/omarchy/plugins/jespermakes.bambu-printer/bin/bambu`.

## Where things are

| File | What it is |
|---|---|
| `bin/bambu` | Everything that talks to the printer. One Python file, standard library only. |
| `Panel.qml` | The bar icon and panel (Quickshell). It never talks to the printer itself; it runs `bin/bambu`. |
| `manifest.json` | Omarchy plugin manifest. `omarchy plugin validate .` checks it. |
| `~/.config/bambu-printer/printers.json` | The user's printers, mode 600. Holds access codes. **Never print, paste or commit it.** |

How the widget gets data: it runs `bin/bambu config` (which printers exist, no codes) and one
long-running `bin/bambu watch --json`, which prints one JSON object per line per printer
whenever something changes. Each object has an `id`. `{"ok": false, "id": ..., "error": ...}`
means that printer is unreachable. When `printers.json` changes, `watch` exits with 0 and the
widget restarts it. Actions run as separate `bin/bambu <command> -p <id>` processes.

If you change the JSON shape from `summarize()`, update `Panel.qml` in the same change.

## The protocol, short

- **Status and commands:** MQTT 3.1.1 over TLS, port 8883, username `bblp`, password = the
  printer's access code. Subscribe `device/<serial>/report`, publish to `device/<serial>/request`.
  `{"pushing": {"command": "pushall"}}` asks for the full state; after that the printer sends
  changes. Bambu firmware differs by model: the H2D packs temperatures as `target << 16 | current`
  in `device.extruder.info[].temp`, older models use `nozzle_temper` and friends. `summarize()`
  handles both; add new shapes there.
- **Commands** (`print.pause`, `print.resume`, `print.stop`, `print.print_speed`,
  `system.ledctrl`) need **Developer Mode** on the printer since the 2025 firmware. Without
  it the printer answers with a reason containing `verify failed`. That is not a bug to fix
  in code; it is a switch on the printer, and the plugin explains it.
- **Camera:** H2D and X1 stream RTSPS on port 322 (`ffmpeg` grabs one frame). P1 and A1
  send JPEG frames over TLS on port 6000 after an 80 byte login (`jpeg_frame()`). The
  6000 path is **untested**. If you get it working on a P1 or A1, that is the most useful
  fix this project can receive.
- **Discovery:** printers multicast SSDP on UDP 2021, and the plugin also scans the local
  /24 for port 8883 and reads the printer's TLS certificate, whose CN is the serial number.
- **Certificate pinning:** the certificate is self-signed, so `tls_socket()` checks its SHA-256
  against `cert` in the printer's config before anything secret goes out, on 8883, 322 and 6000
  (the H2D shows the same certificate on all of them). Setup saves it; a config without one is
  pinned on its first successful login. **Never change a saved address on the serial alone**:
  `same_printer()` requires the pinned certificate, because a serial is just text anyone can put
  in a certificate. Do not add a "just reconnect" path around a `CertChanged`; the fix for a real
  certificate change is `bambu setup`, where the user confirms the printer.
- Good protocol references: the OpenBambuAPI project and the ha-bambulab Home Assistant
  integration on GitHub.

## Traps already found (do not rediscover them)

1. **Omarchy's firewall (ufw) drops incoming traffic by default**, so SSDP announcements never
   arrive. That is why the scan exists. Do not "fix" discovery by opening the firewall; the
   scan needs no sudo.
2. **Wi-Fi scans need a patient timeout.** A cold ARP lookup takes a second or more. At 0.8 s
   the scan missed a printer that answers in 0.7 s once known. Keep 2.5 s and the second pass.
3. **ffmpeg 8+ verifies TLS** and rejects the printer's self-signed certificate. It needs
   `-tls_verify 0`, and older ffmpeg rejects that option. `snapshot()` tries both.
4. **Quickshell: the panel is an `Item`, and its built-in names are taken.** A property called
   `top` stopped the whole widget from loading ("Cannot override FINAL property"); `states`
   shadows Qt's state machinery, which is why ours is `printerStates`. Avoid `top`, `left`,
   `width`, `height`, `state`, `states`, `visible`, `opacity`, `data`, `children`. Check the
   shell log before assuming your QML works: `journalctl --user -n 100 | grep bambu-printer`.
5. **QML only notices a new object.** `printerStates` and `lastPrinterStates` are replaced, never
   mutated in place (`Object.assign({}, ...)`), or the bindings will not update.
6. **The printer's countdown and "remain" values** are the printer's own; do not "correct" them.
7. **Never put the access code in a command line** (`ps` shows it to every program). ffmpeg
   gets the camera address through a mode 600 concat file (`snapshot()`); ffmpeg has no other
   way to take RTSP credentials (`-/i` does not exist in 6 or 9). Never print ffmpeg's stderr:
   it echoes that address.
8. **Port 2021 may be taken** by Bambu Studio on the same laptop; the listener then gives up
   quietly and the scan carries discovery.

## Testing a change

- The CLI: run it against the real printer with read-only commands. Keep a copy of the
  user's `printers.json` before you touch the config code.
- Throwaway config: `XDG_CONFIG_HOME=/tmp/bambu-test bin/bambu ...` keeps your tests away
  from the user's real printers. You can add a fake printer at an address nothing answers
  on, to see how errors look.
- The widget: `omarchy plugin validate .`, then restart the shell (`omarchy-restart-shell`)
  and read the log line above. Open the panel with `omarchy-shell jespermakes.bambu-printer open`.
- `python3 -m py_compile bin/bambu` before you commit.

## Fixing it so others get the fix too

Do not edit the installed copy in `~/.config/omarchy/plugins/` for a lasting fix:
`omarchy plugin update` will clash with your change. Fork the repo, fix it there, test it,
and send a pull request to https://github.com/jespermakes/omarchy-bambu with:

- the printer model and firmware (`bambu doctor` prints both, and never the access code),
- what was broken, and the `doctor` output before and after,
- a line in the README's "Tested on" table if you tested a new model.

Keep it one file of standard-library Python. No new dependencies without a very good reason;
"works on a fresh Omarchy install" is the whole point.

## Out of scope, on purpose

Starting prints, uploading files, and raw G-code. Those belong in the slicer, where the user
sees what they send. A pull request that adds them will be declined, however well it is written.
