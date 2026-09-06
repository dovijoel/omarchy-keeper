# Keeper for Omarchy

Search your [Keeper](https://www.keepersecurity.com/) vault from the Omarchy
menu or a keybinding, copy or type a password, username or TOTP code, and add
new logins — without opening the Keeper app or browser extension.

It is a thin, themed front end over [Keeper Commander](https://github.com/Keeper-Security/Commander),
Keeper's official open-source CLI. The UI is Omarchy's own menu, so it follows
your theme automatically.

## What you get

- **SUPER + SHIFT + /** (Omarchy's stock "passwords" chord) opens a native
  picker: search-as-you-type over titles, usernames and sites, a detail pane
  for the highlighted record, and one chord per action.

  | Key | Action |
  |---|---|
  | type | filter the list — every word must match the title, username or site |
  | `↵` | copy the password (or type it, if that is your default action) |
  | `Ctrl+↵` | type the password into the window behind the picker |
  | `Ctrl+U` / `Ctrl+Shift+U` | copy / type the username |
  | `Ctrl+T` | fetch and show the one-time code with its countdown; again to copy it |
  | `Ctrl+O` | open the site in the browser |
  | `Ctrl+D` | load the full record (notes, custom fields); again to reveal / hide masked values |
  | `Ctrl+1` … `Ctrl+9` | copy the numbered note or custom field shown in the detail pane (loads details first if needed) |
  | `Ctrl+N` / `Ctrl+E` | add a login / edit the highlighted one, in place |
  | `Ctrl+R` | refresh the vault index |
  | `Esc` | clear the search, then close |

- **Add and edit in place.** `Ctrl+N` opens a form (title, username, site,
  password, notes); `Ctrl+E` edits the highlighted record. Keeper generates
  a strong password by default and it lands on the clipboard after saving;
  `Ctrl+G` switches to typing your own, `Ctrl+H` shows it, `Ctrl+↵` saves.
  `Ctrl+K` cycles the kind: Login, API key (a login record whose password
  field holds the key) or Secure note.
- **API keys, tokens and notes.** Keeper has no dedicated API-key record type;
  the plugin supports the three ways people store them:
  - a *Login* record with the key in the password field (`Enter` copies it),
    which is what the **API key** kind in the add form creates;
  - a *Secure Note* (`Enter` copies the masked note body);
  - masked custom fields of type `secret` on any record, shown numbered in the
    detail pane after `Ctrl+D` and copied with `Ctrl+1` … `Ctrl+9`.
  Record notes are copied the same way (`Notes` is always item 1 when present).
- **Keeper** submenu in the Omarchy menu (`SUPER + SPACE` → Keeper, or
  `omarchy menu summon keeper`) with the picker, *Add a login…*, index
  refresh, sign-in and settings. A menu-style fallback picker built from
  `omarchy menu select` is there too.
- Secrets go to the clipboard flagged as sensitive, so Omarchy's clipboard
  history never records them, and the clipboard is cleared again after 45 s
  (configurable). *Type* actions use `wtype` and never touch the clipboard.
- Lookups are instant: a small helper keeps Keeper Commander logged in and
  synced in memory (a fresh CLI call costs about 8 s on a large vault) and
  exits after 30 idle minutes. Everything still works without it, just slower.
- The record list is cached locally (titles, usernames and URLs only — never
  passwords) so the picker opens immediately.
- Settings: default action (ask / copy / type), clipboard clear delay,
  background helper on/off, sign-in method (master password, master password
  + 2FA, enterprise SSO).

## Install

Requirements: Omarchy 4.x, `pipx` (Omarchy ships it as `python-pipx`), a
running Secret Service (gnome-keyring, which Omarchy starts by default) and
`socat` for the background helper (optional; present on Omarchy).

```bash
git clone https://github.com/dovijoel/omarchy-keeper ~/.config/omarchy/plugins/dovijoel.keeper
~/.config/omarchy/plugins/dovijoel.keeper/install.sh
omarchy-keeper-login
```

Or, once listed on the marketplace: `omarchy plugin add https://github.com/dovijoel/omarchy-keeper.git --enable`,
then run `install.sh` from `~/.config/omarchy/plugins/dovijoel.keeper/` to link
the scripts, add the menu rows and the keybinding (plugins cannot do that for
you — see "How it fits into Omarchy" below).

`install.sh`:

1. symlinks `bin/omarchy-keeper-*` into `~/.local/bin`,
2. adds a `keeper` submenu to `~/.config/omarchy/extensions/omarchy-menu.jsonc`,
3. registers and enables the overlay with the Omarchy shell (linking the repo
   into `~/.config/omarchy/plugins/` if you cloned it elsewhere),
4. asks, then rebinds `SUPER + SHIFT + SLASH` from 1Password to the Keeper
   overlay in `~/.config/hypr/bindings.lua` (`--yes` skips the prompt).

`install.sh --uninstall` reverses all of it and stops the background helper. Both steps are idempotent; the
menu rows and the binding are wrapped in `omarchy-keeper begin/end` markers.

### Enrolment (one time)

`omarchy-keeper-login` asks how you sign in, then opens a floating terminal that:

1. installs Keeper Commander with `pipx install keepercommander` if needed,
2. asks for your Keeper email and data centre,
3. runs `keeper shell` so you can log in with your master password, 2FA /
   Keeper Push, or the SSO browser flow,
4. immediately enrols the device: `this-device register`,
   `persistent-login on`, `timeout 30d`, `ip-auto-approve on` and, for the
   2FA method, `2fa_expiration forever`,
5. checks that `keeper list` now works without a prompt and builds the index.

Your master password is only ever typed into Commander inside that terminal.
The resulting session material is stored by Commander in the OS keychain
(gnome-keyring) — nothing secret is written to `~/.config/omarchy-keeper`.

If your Keeper administrator has disabled *Stay Logged In* by policy, the
enrolment self-test fails and non-interactive use is not possible.

## Usage

| Where | What |
|---|---|
| `SUPER + SHIFT + /` | The picker (see the key table above) |
| Omarchy menu → Keeper → Add a login… | The in-overlay form (`omarchy-keeper-add` is a menu-based fallback) |
| Omarchy menu → Keeper → Settings | Default action, clear delay, background helper, sign-in method |
| `omarchy-keeper-pick --copy --totp` | CLI: menu-style picker that copies the TOTP code straight away |
| `omarchy-keeper-sync --notify` | Refresh the cached index |
| `omarchy-keeper-config set DEFAULT_ACTION copy` | Change a setting from the terminal |
| `omarchy-keeper-daemon status|stop|start` | Inspect or control the background helper |
| `omarchy-shell shell summon dovijoel.keeper '{"query":"github"}'` | Open the picker with a search pre-filled (`"mode":"add"` opens the form, `"details":true` loads the record) |

Settings live in `~/.config/omarchy-keeper/config`; the record index in
`~/.cache/omarchy-keeper/index.json` (mode 600). The helper listens on
`$XDG_RUNTIME_DIR/omarchy-keeper-<uid>.sock` (mode 600).

## How it fits into Omarchy

- Menu rows are declared in the user extension file
  `~/.config/omarchy/extensions/omarchy-menu.jsonc`; the picker uses
  `omarchy menu select` and `omarchy menu input`, so nothing under
  `/usr/share/omarchy` is modified and updates cannot break it.
- The picker is a Quickshell overlay plugin (`Keeper.qml`) registered as
  `dovijoel.keeper`, so it installs and updates with `omarchy plugin add /
  update` and is summoned with `omarchy-shell shell toggle dovijoel.keeper`.
  It shares the menu's theme tokens, so it follows your theme. All Keeper
  access goes through `bin/omarchy-keeper-action`; QML never sees the master
  password or session tokens.
- Omarchy shell plugins cannot install keybindings, run post-install hooks or
  add menu rows, which is why `install.sh` exists.

## Security model

- Anyone who can use your unlocked desktop can read your passwords through
  this plugin — the same as the Keeper desktop app with *Stay Logged In*.
  Lock your screen.
- Copied secrets carry the `x-kde-passwordManagerHint` MIME type
  (`wl-copy --sensitive`); Omarchy's clipboard history skips them.
- `Add a login…` passes the password to Commander as a command-line argument,
  which is briefly visible to other processes of your user. Prefer
  *Generate a strong password*, which never leaves Commander.
- Persistent login is a Keeper feature; revoke it any time from the Keeper
  web vault (Settings → Devices) or with
  `keeper --config ~/.config/omarchy-keeper/commander.json this-device persistent-login off`.

## Developing

Clone straight into `~/.config/omarchy/plugins/dovijoel.keeper`: the shell
hot-reloads QML saved under that directory (it does not follow symlinks).
`omarchy plugin validate .` checks the manifest; `journalctl --user -f` and
`$XDG_RUNTIME_DIR/quickshell/by-id/*/log.log` show QML errors.

## Roadmap

- Folder picker when adding records.
- Pre-fill the add form from the active browser window.
- Autofill helper for the focused browser tab.

## License

MIT — see [LICENSE](LICENSE).
