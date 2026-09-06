# Marketplace submission (ready to file)

File at: https://github.com/omacom/omarchy-plugin-marketplace/issues/new?template=submit-plugin.yml

**Title:** `[Plugin]: Keeper — password picker for the Keeper vault`

**Repository URL:** https://github.com/dovijoel/omarchy-keeper

**Category:** Productivity

**Tags:** Security, Launcher, Quickshell

**Maintainer notes:**

> Native Quickshell overlay for the Keeper password manager: search the vault
> by title, username or site, copy or type a password / username / TOTP code,
> open the site, and add or edit logins in place. Built on Keeper's official
> open-source CLI, Keeper Commander (installed with pipx; not bundled).
>
> Installation and removal are documented in the README and handled by
> `install.sh` / `install.sh --uninstall`. The script links helper scripts into
> ~/.local/bin, adds a Keeper submenu to ~/.config/omarchy/extensions/omarchy-menu.jsonc
> between marker comments, and asks before rebinding SUPER+SHIFT+/ (Omarchy's
> stock 1Password chord). Nothing under /usr/share/omarchy is touched.
>
> Dependencies: keepercommander (pipx), jq, wl-clipboard, wtype (all present on
> Omarchy except keepercommander, which the enrolment flow installs), socat for
> the optional background helper. Session material is stored by Commander in
> the OS keychain (gnome-keyring); the plugin never handles the master password.
> License: MIT.

**Checklist:** all five boxes apply.

Before filing: add a `preview.png` taken against a demo vault (the screenshots
in development show real records) and bump `version` in `manifest.json`.
