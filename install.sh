#!/bin/bash
# Installs (or removes) the omarchy-keeper scripts, menu rows and keybinding
# for the current user. Everything lives under $HOME; nothing needs sudo and
# nothing under /usr/share/omarchy is touched.
#
#   ./install.sh              install / update
#   ./install.sh --uninstall  remove the symlinks, menu rows and keybinding

set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
bin_dir="$HOME/.local/bin"
menu_file="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/extensions/omarchy-menu.jsonc"
bindings_file="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/bindings.lua"
begin_marker="omarchy-keeper begin"
end_marker="omarchy-keeper end"

strip_block() {
  # Removes the marker-delimited block from $1 in place (no-op when absent).
  local file="$1"
  [[ -f $file ]] || return 0
  grep -q "$begin_marker" "$file" || return 0
  cp "$file" "$file.bak"
  perl -0pi -e "s/\\n?[^\\n]*\Q$begin_marker\E.*?\Q$end_marker\E[^\\n]*\\n?/\\n/s" "$file"
}

uninstall() {
  "$here/bin/omarchy-keeper-daemon" stop >/dev/null 2>&1 || true
  for f in "$here"/bin/omarchy-keeper-*; do
    local name link
    name=$(basename "$f")
    link="$bin_dir/$name"
    [[ -L $link && $(readlink -f "$link") == "$(readlink -f "$f")" ]] && rm -f "$link"
  done
  strip_block "$menu_file"
  strip_block "$bindings_file"
  hyprctl reload >/dev/null 2>&1 || true
  echo "omarchy-keeper removed. Your settings in ~/.config/omarchy-keeper and the"
  echo "Commander session in the keychain were left in place; delete them with:"
  echo "  keeper --config ~/.config/omarchy-keeper/commander.json logout; rm -r ~/.config/omarchy-keeper ~/.cache/omarchy-keeper"
}

install() {
  mkdir -p "$bin_dir"
  for f in "$here"/bin/omarchy-keeper-*; do
    [[ $f == *.py ]] && continue
    chmod +x "$f"
    ln -sfn "$f" "$bin_dir/$(basename "$f")"
  done
  echo "Linked scripts into $bin_dir"

  # Register the overlay with the shell when the repo lives (or is linked)
  # in the plugins directory, which is what `omarchy plugin add` does too.
  local plugins_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"
  local plugin_id
  plugin_id=$(jq -r .id "$here/manifest.json")
  if [[ ! -e "$plugins_dir/$plugin_id" ]]; then
    mkdir -p "$plugins_dir"
    ln -s "$here" "$plugins_dir/$plugin_id"
    echo "Linked the plugin into $plugins_dir/$plugin_id (clone straight into that path for hot reload)"
  fi
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  omarchy plugin enable "$plugin_id" >/dev/null 2>&1 || true

  # Menu rows: replace any previous block, then insert before the closing brace.
  mkdir -p "$(dirname "$menu_file")"
  if [[ ! -f $menu_file ]]; then
    printf '{\n}\n' >"$menu_file"
  fi
  strip_block "$menu_file"
  perl -0pi -e '
    my $rows = do { local $/; open my $fh, "<", $ENV{KEEPER_MENU_ROWS} or die; <$fh> };
    s/\n?\s*\}\s*$/\n$rows}\n/s or die "no closing brace in menu file";
  ' "$menu_file" 2>/dev/null || {
    echo "Could not update $menu_file; append the rows from $here/menu.jsonc by hand." >&2
  }
  omarchy-menu refresh >/dev/null 2>&1 || true
  echo "Added the Keeper submenu to $menu_file"

  # Keybinding.
  if [[ -f $bindings_file ]]; then
    strip_block "$bindings_file"
    printf '\n%s' "$(cat "$here/bindings.lua")" >>"$bindings_file"
    printf '\n' >>"$bindings_file"
    if hyprctl reload >/dev/null 2>&1; then
      errors=$(hyprctl configerrors 2>/dev/null || true)
      if [[ -n $errors && $errors != *"No errors"* ]]; then
        echo "Hyprland reported config errors after adding the keybinding:" >&2
        echo "$errors" >&2
      else
        echo "Bound SUPER+SHIFT+/ to the Keeper overlay in $bindings_file"
      fi
    fi
  else
    echo "No $bindings_file found; add this to your Hyprland bindings by hand:"
    cat "$here/bindings.lua"
  fi

  echo
  if command -v keeper >/dev/null 2>&1; then
    echo "Keeper Commander is installed."
  else
    echo "Keeper Commander is not installed yet; the enrolment step installs it with pipx."
  fi
  echo "Next: run  omarchy-keeper-login  (or Keeper → Log in in the Omarchy menu) to enrol this device."
}

case "${1:-}" in
  --uninstall | uninstall | remove) uninstall ;;
  "" | install | --install) KEEPER_MENU_ROWS="$here/menu.jsonc" install ;;
  *)
    echo "Usage: $0 [--uninstall]" >&2
    exit 1
    ;;
esac
