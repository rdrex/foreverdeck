#!/usr/bin/env bash
# One-file Steam Deck WoW setup. The Python setup program is embedded below.
# Run from Konsole with: bash ~/Downloads/steam-deck-wow.sh
set -euo pipefail
umask 077

RUNTIME_RELEASE='20261026'
RUNTIME_VERSION='3.13.18'
RUNTIME_SHA256='df15fe60d3ff55bf9dcf25824b5572756bb8816ff93865a273d3301d7066a8b7'
RUNTIME_URL='https://github.com/astral-sh/python-build-standalone/releases/download/20261026/cpython-3.13.18%2B20261026-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz'
# Runtime licenses are included in the downloaded distribution.
# https://github.com/astral-sh/python-build-standalone/releases/tag/20261026

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

python_works() {
    "$1" -I -c 'import sys; assert sys.version_info >= (3, 10); import ssl, zlib, fcntl, hashlib, urllib.request, dataclasses, pathlib' \
        >/dev/null 2>&1
}

install_private_python() (
    # The lock is held by this subshell, then released before the setup runs.
    flock --exclusive 9
    if python_works "$private_python"; then
        return
    fi

    stage=$(mktemp -d "$runtime_root/.install.XXXXXXXX")
    trap 'rm -rf -- "$stage"' EXIT
    printf 'Installing Python %s in %s\n' "$RUNTIME_VERSION" "$runtime_target"
    curl --fail --location --proto '=https' --proto-redir '=https' \
        --retry 2 --connect-timeout 20 --max-time 600 \
        --output "$stage/python.tar.gz" "$RUNTIME_URL"
    printf '%s  %s\n' "$RUNTIME_SHA256" "$stage/python.tar.gz" | sha256sum --check --status \
        || fail 'The Python download failed checksum verification. Run the script again to retry.'

    tar --extract --gzip --no-same-owner --file "$stage/python.tar.gz" --directory "$stage"
    python_works "$stage/python/bin/python3" \
        || fail 'The downloaded Python runtime could not start on this system.'

    # Replace an interrupted or damaged installation after the new one passes its probe.
    if [[ -e "$runtime_target" || -L "$runtime_target" ]]; then
        mv -T -- "$runtime_target" "$stage/previous"
    fi
    if ! mv -T -- "$stage/python" "$runtime_target"; then
        if [[ -e "$stage/previous" || -L "$stage/previous" ]]; then
            mv -T -- "$stage/previous" "$runtime_target"
        fi
        fail 'Could not put the Python runtime in place. Check your available disk space.'
    fi
    python_works "$private_python" \
        || fail 'The installed Python runtime could not start. Run the script again to repair it.'
) 9>"$runtime_root/install.lock"

[[ $(uname -s) == Linux ]] || fail 'Run this script in Konsole on your Steam Deck.'
[[ $(uname -m) == x86_64 ]] || fail 'This setup supports the Steam Deck x86-64 processor.'
(( EUID != 0 )) || fail 'Run this script as your normal Steam Deck user.'

state_root="$HOME/.local/share/steam-deck-wow"
runtime_root="$state_root/runtime"
runtime_target="$runtime_root/cpython-$RUNTIME_VERSION+$RUNTIME_RELEASE"
private_python="$runtime_target/bin/python3"
python_command=''
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && python_works "$candidate"; then
        python_command=$(command -v "$candidate")
        break
    fi
done

if [[ -z "$python_command" ]]; then
    if ! python_works "$private_python"; then
        for required in curl tar sha256sum flock mktemp mv rm; do
            command -v "$required" >/dev/null 2>&1 \
                || fail "Required command is unavailable: $required"
        done
        mkdir -p -- "$runtime_root"
        install_private_python
    fi
    python_command="$private_python"
fi

printf 'Using Python at %s\n' "$python_command"
mkdir -p -- "$state_root"
payload_path=$(mktemp "$state_root/.setup.XXXXXXXX.py")
trap 'rm -f -- "$payload_path"' EXIT
# Write the embedded program to a file so Python retains the terminal for menus.
cat > "$payload_path" <<'STEAM_DECK_WOW_EMBEDDED_PYTHON'
#!/usr/bin/env python3
"""Set up Battle.net and World of Warcraft utilities in Steam Deck Desktop Mode.

Run with python3 steam-deck-wow.py in Konsole. The setup menu can be run again
to resume Battle.net setup, select more games, or update utilities.
"""

import argparse
import base64
import binascii
import hashlib
import json
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen
from dataclasses import dataclass
from datetime import datetime, timezone
import os
from pathlib import Path
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import zlib


BATTLENET_PAGE = "https://download.battle.net/en-us/desktop"
BATTLENET_DOWNLOAD = (
    "https://www.battle.net/download/getInstallerForGame"
    "?os=win&version=LIVE&gameProgram=BATTLENET_APP"
)
BATTLENET_CDN = "https://downloader.battle.net/download/installer/win/1.0.66/Battle.net-Setup.exe"
ZYGOR_MEMBERS = "https://zygorguides.com/members/"
EXPERIMENTAL = "proton_experimental"
DESKTOP_MARKER = "X-SteamDeckWoWSetup=true"

# Game Version labels may vary by region or as Classic progresses.
WOW_EDITIONS = {
    "retail": ("World of Warcraft (Retail)", "_retail_"),
    "classic": ("WoW Classic progression (Mists of Pandaria Classic)", "_classic_"),
    "era": ("WoW Classic Era (includes Classic Era Hardcore realms)", "_classic_era_"),
    "anniversary": ("Burning Crusade Classic Anniversary", "_anniversary_"),
    "forever": ("World of Warcraft: Forever", "_forever_"),
    "ptr": ("Retail Public Test Realm (if offered)", "_ptr_"),
}


class SetupError(Exception):
    """An actionable problem encountered during setup."""


def atomic_write(path: Path, payload: bytes, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=f".{path.name}.", delete=False) as stream:
            temporary_path = Path(stream.name)
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        temporary_path.chmod(mode)
        temporary_path.replace(path)
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def write_desktop_launcher(
    path: Path, name: str, command: list[str], icon: str = "applications-games"
) -> None:
    def exec_arg(arg: str) -> str:
        # Exec quoting is specified by the Desktop Entry spec, separate from shell quoting.
        if any(character in arg for character in "\r\n\x00"):
            raise SetupError("Desktop launcher paths must fit on one line.")
        escaped = re.sub(r'(["`$\\])', r'\\\1', arg.replace("%", "%%"))
        return '"' + escaped.replace("\\", "\\\\") + '"'

    contents = (
        f"#!/usr/bin/env xdg-open\n[Desktop Entry]\nType=Application\nName={name}\n"
        f"Exec={' '.join(map(exec_arg, command))}\nIcon={icon}\nTerminal=false\n"
        f"Categories=Game;\n{DESKTOP_MARKER}\n"
    )
    if path.exists() and DESKTOP_MARKER not in path.read_text(encoding="utf-8", errors="replace").splitlines():
        path = path.with_name(f"{path.stem}-steam-deck-wow.desktop")
        if path.exists() and DESKTOP_MARKER not in path.read_text(encoding="utf-8", errors="replace").splitlines():
            raise SetupError(f"An existing desktop launcher occupies {path}.")
    atomic_write(path, contents.encode(), mode=0o755)
    print(f"Desktop shortcut: {path}")


def desktop_directory() -> Path:
    if shutil.which("xdg-user-dir"):
        query = subprocess.run(["xdg-user-dir", "DESKTOP"], capture_output=True, text=True)
        location = Path(query.stdout.strip())
        if query.returncode == 0 and location.is_absolute() and location != Path.home():
            return location
    return Path.home() / "Desktop"


def choose(prompt: str, options: dict[str, str], defaults: tuple[str, ...], multiple: bool = False) -> list[str]:
    keys = list(options)
    print(f"\n{prompt}")
    numbered = {str(index): key for index, key in enumerate(keys, 1)}
    for number, key in numbered.items():
        print(f"  {number}. {options[key]}")
    default_numbers = ",".join(str(keys.index(key) + 1) for key in defaults)
    while True:
        label = "Numbers separated by commas" if multiple else "Number"
        answer = input(f"{label} [{default_numbers}]: ").strip() or default_numbers
        parts = [part.strip() for part in answer.split(",")]
        if (multiple or len(parts) == 1) and all(part in numbered for part in parts):
            picked = list(dict.fromkeys(numbered[part] for part in parts))
            if "skip" not in picked or len(picked) == 1:
                return picked
        print("Enter a listed number. Choose Skip by itself.")


def read_binary_shortcuts(payload: bytes) -> dict:
    """Parse Steam binary KeyValues, retaining raw string and numeric values."""
    cursor = 0

    def terminated_string() -> bytes:
        nonlocal cursor
        end = payload.find(b"\0", cursor)
        if end < 0:
            raise ValueError("unterminated string")
        value = payload[cursor:end]
        cursor = end + 1
        return value

    def fields(depth: int = 0) -> dict:
        nonlocal cursor
        if depth > 32:
            raise ValueError("unexpected nesting")
        result = {}
        while cursor < len(payload):
            kind = payload[cursor]
            cursor += 1
            if kind == 8:
                return result
            name = terminated_string()
            if name in result:
                raise ValueError("duplicate field")
            if kind == 0:
                value = fields(depth + 1)
            elif kind == 1:
                value = terminated_string()
            else:
                length = {2: 4, 3: 4, 4: 4, 6: 4, 7: 8, 10: 8}.get(kind)
                if length is None or cursor + length > len(payload):
                    raise ValueError(f"unsupported or truncated field type {kind}")
                value = payload[cursor:cursor + length]
                cursor += length
            result[name] = kind, value
        raise ValueError("missing end marker")

    result = fields()
    if cursor != len(payload) or set(result) != {b"shortcuts"} or result[b"shortcuts"][0] != 0:
        raise ValueError("unexpected shortcuts.vdf structure")
    shortcuts = result[b"shortcuts"][1]
    if any(not key.isdigit() or kind != 0 for key, (kind, _) in shortcuts.items()):
        raise ValueError("unexpected shortcut entry")
    return shortcuts


def write_binary_shortcuts(shortcuts: dict) -> bytes:
    def encode(fields: dict) -> bytes:
        parts = []
        for key, (kind, value) in fields.items():
            parts.extend((bytes([kind]), key, b"\0"))
            parts.append(encode(value) if kind == 0 else value)
            if kind == 1:
                parts.append(b"\0")
        parts.append(b"\x08")
        return b"".join(parts)

    return encode({b"shortcuts": (0, shortcuts)})


def shortcut_field(shortcut: dict, name: bytes, kind: int, default: bytes = b"") -> bytes:
    return next((value for key, (tag, value) in shortcut.items() if key.lower() == name.lower() and tag == kind), default)


def shortcut_id(shortcut: dict) -> int:
    value = shortcut_field(shortcut, b"appid", 2)
    return struct.unpack("<I", value)[0] if value else 0


def set_shortcut(shortcuts: dict, name: str, target: Path, compat_data: Path, hidden: bool) -> tuple[int, dict]:
    # The prefix identifies entries managed by this script. The target changes after setup.
    prefix_option = f"STEAM_COMPAT_DATA_PATH={shlex.quote(str(compat_data))} "
    options = prefix_option
    if name == "Battle.net":
        # Battle.net's embedded browser needs these Wine options on affected builds.
        options += "WINE_SIMULATE_WRITECOPY=1 WINEDLLOVERRIDES=locationapi=d "
    options += "%command%"
    exe = f'"{target}"'
    if any(character in str(target) for character in '\r\n"'):
        raise SetupError(f"Steam cannot safely quote this executable path: {target}")
    managed = [
        shortcut for _, shortcut in shortcuts.values()
        if shortcut_field(shortcut, b"AppName", 1) == name.encode()
        and shortcut_field(shortcut, b"LaunchOptions", 1).startswith(os.fsencode(prefix_option))
    ]
    if len(managed) > 1:
        raise SetupError(f"More than one managed {name} entry was found. Remove the duplicate in Steam and rerun.")

    used_ids = {shortcut_id(shortcut) for _, shortcut in shortcuts.values()}
    if managed:
        shortcut = managed[0]
        app_id = shortcut_id(shortcut)
        if not app_id or sum(shortcut_id(entry) == app_id for _, entry in shortcuts.values()) != 1:
            raise SetupError(f"Steam has an invalid or duplicate AppID for {name}.")
    else:
        app_id = zlib.crc32(os.fsencode(exe + name)) | 0x80000000
        while app_id in used_ids:
            app_id = ((app_id + 1) & 0xFFFFFFFF) | 0x80000000
        index = 1 + max((int(key) for key in shortcuts), default=-1)
        shortcut = {
            b"appid": (2, struct.pack("<I", app_id)),
            b"AppName": (1, name.encode()),
            b"icon": (1, b""),
            b"ShortcutPath": (1, b""),
            b"IsHidden": (2, struct.pack("<I", int(hidden))),
            b"AllowDesktopConfig": (2, struct.pack("<I", 1)),
            b"AllowOverlay": (2, struct.pack("<I", 1)),
            b"OpenVR": (2, bytes(4)),
            b"Devkit": (2, bytes(4)),
            b"DevkitGameID": (1, b""),
            b"DevkitOverrideAppID": (2, bytes(4)),
            b"LastPlayTime": (2, bytes(4)),
            b"FlatpakAppID": (1, b""),
            b"tags": (0, {}),
        }
        shortcuts[str(index).encode()] = (0, shortcut)

    for key, value in ((b"Exe", exe), (b"StartDir", f'"{target.parent}"'), (b"LaunchOptions", options)):
        stored_key = next((stored for stored in shortcut if stored.lower() == key.lower()), key)
        if key == b"LaunchOptions" and managed:
            continue
        shortcut[stored_key] = (1, os.fsencode(value))
    return app_id, shortcut


def steam_running() -> bool:
    for process in Path("/proc").iterdir():
        if not process.name.isdecimal():
            continue
        try:
            if process.stat().st_uid != os.getuid():
                continue
            if (process / "comm").read_text().strip() in {"steam", "steam.sh"}:
                status = (process / "status").read_text()
                if not re.search(r"^State:\s*Z", status, re.MULTILINE):
                    return True
        except (OSError, UnicodeError):
            continue
    return False


def stop_steam(steam: str) -> None:
    if not steam_running():
        return
    input("\nClose running Steam games, then press Enter to restart Steam for the library update. ")
    try:
        subprocess.run([steam, "-shutdown"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
    except subprocess.TimeoutExpired:
        pass
    deadline = time.monotonic() + 45
    while steam_running() and time.monotonic() < deadline:
        time.sleep(0.5)
    time.sleep(1)
    if steam_running():
        raise SetupError("Steam is still running. Exit it from the Steam menu, then rerun this script.")


def launch_steam(steam: str, app_id: int | None = None) -> None:
    command = [steam, steam_uri(app_id)] if app_id is not None else [steam]
    subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)


def steam_uri(app_id: int) -> str:
    return f"steam://rungameid/{(app_id << 32) | 0x02000000}"


def find_steam_root() -> Path:
    home = Path.home()
    for candidate in (home / ".steam/root", home / ".local/share/Steam", home / ".steam/steam"):
        if (candidate / "config/config.vdf").is_file():
            return candidate.resolve()
    raise SetupError("Open the Steam client in Desktop Mode and sign in once, then rerun setup.")


def select_steam_account(root: Path, requested_id: int | None) -> int:
    loginusers = root / "config/loginusers.vdf"
    if not loginusers.is_file():
        raise SetupError("Sign in to Steam in Desktop Mode, then rerun setup.")
    accounts = read_steam_accounts(loginusers.read_text(encoding="utf-8-sig", errors="replace"))
    if not accounts:
        raise SetupError("Sign in to Steam in Desktop Mode, then rerun setup.")
    if requested_id is not None:
        if requested_id not in {account_id for account_id, _, _ in accounts}:
            raise SetupError(f"Steam account {requested_id} is absent from this Deck's login list.")
        return requested_id
    if len(accounts) == 1:
        return accounts[0][0]
    options = {str(account_id): f"{persona} ({account_id})" for account_id, persona, _ in accounts}
    default = next((account_id for account_id, _, recent in accounts if recent), accounts[0][0])
    return int(choose("Which Steam account should get the Battle.net shortcut?", options, (str(default),))[0])


@dataclass
class SteamLibrary:
    command: str
    root: Path
    user_config: Path
    data: Path
    proton: str

    def update(self, name: str, executable: Path, *, hidden: bool = False) -> int:
        stop_steam(self.command)
        shortcuts_file = self.user_config / "shortcuts.vdf"
        config_file = self.root / "config/config.vdf"
        original_shortcuts = shortcuts_file.read_bytes() if shortcuts_file.exists() else None
        original_config = config_file.read_bytes()
        shortcuts = read_binary_shortcuts(original_shortcuts) if original_shortcuts is not None else {}
        app_id, entry = set_shortcut(shortcuts, name, executable, self.data, hidden)
        new_config = set_compat_tool(original_config.decode("utf-8", errors="surrogateescape"), app_id, self.proton)
        if name == "Battle.net":
            icon = install_artwork(self.user_config / "grid", app_id)
            if not shortcut_field(entry, b"icon", 1):
                icon_key = next((key for key in entry if key.lower() == b"icon"), b"icon")
                entry[icon_key] = (1, os.fsencode(icon))

        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        backup = self.data.parent / "steam-backups" / timestamp
        files = (
            (config_file, original_config, new_config.encode("utf-8", errors="surrogateescape")),
            (shortcuts_file, original_shortcuts, write_binary_shortcuts(shortcuts)),
        )
        for path, original, updated in files:
            if updated != original and original is not None:
                atomic_write(backup / path.name, original, mode=0o600)
        for path, original, updated in files:
            if updated == original:
                continue
            current = path.read_bytes() if path.exists() else None
            if current != original or steam_running():
                raise SetupError("Steam's files changed while setup was preparing the update. Exit Steam and rerun.")
            mode = path.stat().st_mode & 0o777 if path.exists() else 0o600
            atomic_write(path, updated, mode=mode)
        return app_id


def is_exe(path: Path) -> bool:
    if not path.is_file() or path.suffix.lower() != ".exe":
        return False
    with path.open("rb") as stream:
        header = stream.read(64)
        if len(header) < 64 or header[:2] != b"MZ":
            return False
        pe_offset = struct.unpack_from("<I", header, 60)[0]
        if pe_offset < 64 or pe_offset > path.stat().st_size - 4:
            return False
        stream.seek(pe_offset)
        return stream.read(4) == b"PE\0\0"


def get_battlenet_installer(cache: Path) -> Path:
    if is_exe(cache):
        return cache
    curl = shutil.which("curl")
    if curl:
        with tempfile.TemporaryDirectory(dir=cache.parent) as staging:
            staged = Path(staging) / cache.name
            print("Downloading Battle.net from Blizzard…", flush=True)
            for url in (BATTLENET_DOWNLOAD, BATTLENET_CDN):
                result = subprocess.run([
                    curl, "--fail", "--location", "--proto", "=https", "--proto-redir", "=https",
                    "--retry", "2", "--connect-timeout", "20", "--max-time", "180",
                    "--output", str(staged), url,
                ])
                if result.returncode == 0 and is_exe(staged):
                    staged.replace(cache)
                    return cache
    print(f"Download the Windows installer from {BATTLENET_PAGE} and enter its local path.")
    selected = local_exe("Battle.net installer path (Enter to cancel): ")
    if selected is None:
        raise SetupError("Battle.net setup needs a Windows installer. Run this script again when you have it.")
    atomic_write(cache, selected.read_bytes(), mode=0o600)
    return cache


def local_exe(prompt: str) -> Path | None:
    while True:
        entry = input(prompt).strip().strip('"\'')
        if not entry:
            return None
        candidate = Path(entry).expanduser().resolve()
        if is_exe(candidate):
            return candidate
        print("That path does not point to a Windows .exe file.")


def find_battlenet(drive_c: Path) -> Path | None:
    for root in ("Program Files (x86)", "Program Files"):
        for filename in ("Battle.net.exe", "Battle.net Launcher.exe"):
            path = drive_c / root / "Battle.net" / filename
            if is_exe(path):
                return path
    return None


def find_zygor(drive_c: Path) -> Path | None:
    locations = list((drive_c / "users").glob("*/AppData/Local/Zygor/Zygor.exe"))
    locations += list((drive_c / "users").glob("*/AppData/Local/Programs/Zygor*/Zygor.exe"))
    locations += list(drive_c.glob("Program Files*/Zygor*/Zygor.exe"))
    return next((path for path in locations if is_exe(path)), None)


def install_zygor(library: SteamLibrary, desktop: Path, drive_c: Path) -> None:
    exe = find_zygor(drive_c)
    installer = None
    if exe is None:
        print(f"Sign in to Zygor's Members Area and download its Windows installer: {ZYGOR_MEMBERS}")
        installer = local_exe("Zygor Windows installer path (Enter for a Members Area shortcut): ")
        if installer is not None:
            staged = library.data.parent / "Zygor-Setup.exe"
            if staged != installer:
                atomic_write(staged, installer.read_bytes(), mode=0o600)
            print("Exit Battle.net from its system tray menu before running Zygor setup.")
            install_id = library.update("Zygor", staged, hidden=True)
            launch_steam(library.command, install_id)
            print("If Zygor setup does not open automatically, look for Zygor in the Steam Library or View > Hidden Games.")
            input("Finish the Zygor installer and fully exit the Zygor Client, then press Enter. ")
            exe = find_zygor(drive_c)
            if exe is None:
                candidate = local_exe("Installed Zygor client .exe (Enter for a Members Area shortcut): ")
                if candidate is not None and candidate.is_relative_to(drive_c.resolve()):
                    exe = candidate
                elif candidate is not None:
                    print("Use the installed client's .exe inside this Battle.net prefix.")
    if exe is None:
        write_desktop_launcher(desktop / "Zygor.desktop", "Zygor Members Area", ["xdg-open", ZYGOR_MEMBERS])
        if installer is not None:
            raise SetupError("The Zygor client executable was not found. The desktop shortcut opens the Members Area.")
    else:
        app_id = library.update("Zygor", exe, hidden=True)
        write_desktop_launcher(desktop / "Zygor.desktop", "Zygor Client", [library.command, steam_uri(app_id)])
        print("Fully exit Battle.net before opening Zygor Client. In Zygor, use Options > Directories if a game is missing.")


def configure_wow(steam: str, app_id: int, drive_c: Path, editions: list[str], wowup: bool) -> None:
    game_roots = [drive_c / parent / "World of Warcraft" for parent in ("Program Files (x86)", "Program Files")]
    if editions:
        print("\nIn Battle.net, sign in and select World of Warcraft. For each edition below, choose it")
        print("under Game Version and click Install. WoW: Forever may have its own page.")
        for edition in editions:
            print(f"  [ ] {WOW_EDITIONS[edition][0]}")
        print("Use Battle.net's Install Location picker if you want the game on a microSD card.")
        print("If Battle.net doesn't open automatically, use Steam > Library > Battle.net > Play.")
        launch_steam(steam, app_id)
        input("Press Enter when you've started your chosen downloads, or to finish setup later. ")
        print("\nWoW game executables at the default location (downloads may still be running):")
        executables = {"wow.exe", "wowclassic.exe", "wowt.exe", "wowb.exe", "wowclassict.exe", "wowclassicb.exe"}
        for edition in editions:
            name, folder = WOW_EDITIONS[edition]
            clients = (file for root in game_roots for file in (root / folder).glob("*.[eE][xX][eE]"))
            client = next((file for file in clients if file.name.lower() in executables and is_exe(file)), None)
            print(f"  {name}: {client or 'game executable not found at the default location.'}")
    else:
        launch_steam(steam)
    if wowup:
        print("\nAfter downloads finish, open WowUp > Options > Clients > Add New for any client it misses.")
        print("Select the game executable in the edition's folder. Default World of Warcraft folder:")
        print(f"  {game_roots[0]}")
        print("For a custom install, use the gear beside Play > Show in Explorer in Battle.net to confirm its location.")
        print("Wine's Z: drive normally maps to / on SteamOS, so Z:\\run\\media is /run/media in WowUp.")


def setup(args: argparse.Namespace, state: Path) -> None:
    steam = shutil.which("steam")
    if not steam:
        raise SetupError("The Steam command is unavailable. Run setup in Steam Deck Desktop Mode.")
    root = find_steam_root()
    account_id = select_steam_account(root, args.steam_account)
    user_config = root / "userdata" / str(account_id) / "config"
    if args.proton:
        proton = args.proton
    else:
        tools = {EXPERIMENTAL: "Proton Experimental (Steam)", **custom_proton_tools(root)}
        proton = choose("Proton version for Battle.net", tools, (EXPERIMENTAL,))[0] if len(tools) > 1 else EXPERIMENTAL

    editions = choose("Which WoW editions do you want to install?", {
        **{key: label for key, (label, _) in WOW_EDITIONS.items()}, "skip": "Skip WoW downloads",
    }, ("retail",), multiple=True)
    editions = [edition for edition in editions if edition != "skip"]
    managers = choose("Which WowUp editions do you want?", {
        "cf": "WowUp with CurseForge", "wago": "WowUp with Wago", "skip": "Skip WowUp",
    }, ("cf",), multiple=True)
    wowup_versions = {}
    for manager in managers:
        if manager != "skip":
            wowup_versions[manager] = input(f"WowUp {'CurseForge' if manager == 'cf' else 'Wago'} release [latest stable]: ").strip() or "latest"
    zygor = choose("Zygor", {
        "skip": "Skip Zygor", "link": "Add a shortcut to the Zygor Members Area",
        "install": "Install Zygor using your downloaded Windows installer",
    }, ("skip",))[0]

    account_state = state / str(account_id)
    compat_data = account_state / "compatdata"
    compat_data.mkdir(parents=True, exist_ok=True)
    desktop = desktop_directory()
    drive_c = compat_data / "pfx/drive_c"
    library = SteamLibrary(steam, root, user_config, compat_data, proton)
    print(f"\nBattle.net Proton data: {compat_data}")
    print(f"Steam account: {account_id}. Stay signed in to this account during setup.")

    failed_managers = []
    for manager, version in wowup_versions.items():
        try:
            install_wowup(manager, state / "wowup", desktop, version)
        except (SetupError, OSError, ValueError, RuntimeError) as error:
            print(f"WowUp {manager} setup needs attention: {error}", file=sys.stderr)
            failed_managers.append(manager)
    if zygor == "link":
        write_desktop_launcher(desktop / "Zygor.desktop", "Zygor Members Area", ["xdg-open", ZYGOR_MEMBERS])

    launcher = find_battlenet(drive_c)
    if launcher is None:
        installer = get_battlenet_installer(account_state / "Battle.net-Setup.exe")
        app_id = library.update("Battle.net", installer)
        launch_steam(steam, app_id)
        print("\nFinish the Battle.net installer. Keep its default install location.")
        print("If the installer doesn't appear, open Steam > Library > Battle.net > Play.")
        print("If Steam reports a compatibility tool error, check that Proton Experimental and its Steam Linux Runtime are installed under Library > Tools.")
        input("When the installer finishes, fully exit Battle.net from its tray menu, then press Enter. ")
        launcher = find_battlenet(drive_c)
        if launcher is None:
            raise SetupError(
                "Battle.net has not appeared in the default folder yet. The Steam entry still opens setup. "
                "Finish setup there, then rerun this script. If Proton fails to start, try a different "
                "installed Proton version using --proton."
            )
    app_id = library.update("Battle.net", launcher)
    if zygor == "install":
        try:
            install_zygor(library, desktop, drive_c)
        except (SetupError, OSError, ValueError) as error:
            failed_managers.append("Zygor")
            print(f"Zygor setup needs attention: {error}", file=sys.stderr)

    wowup_installed = any(manager not in failed_managers for manager in wowup_versions)
    configure_wow(steam, app_id, drive_c, editions, wowup_installed)
    print("\nIn Gaming Mode, open Library > Non-Steam > Battle.net. Choose your edition and click Play.")
    if failed_managers:
        raise SetupError(f"Rerun setup to retry these utilities: {', '.join(failed_managers)}.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--steam-account", type=int, metavar="ACCOUNT_ID", help="Steam userdata account ID")
    parser.add_argument("--proton", metavar="TOOL", help="Steam's internal name for a Proton tool, e.g. proton_experimental")
    args = parser.parse_args()
    desktop_session = os.environ.get("XDG_CURRENT_DESKTOP", "").lower()
    graphical = os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")
    if sys.platform != "linux" or not graphical or "gamescope" in desktop_session:
        parser.exit(1, "Run this script from Konsole in Steam Deck Desktop Mode.\n")
    if os.geteuid() == 0:
        parser.exit(1, "Run this script as your normal Steam Deck user.\n")
    if not sys.stdin.isatty():
        parser.exit(1, "Open Konsole and run the script interactively.\n")
    import fcntl

    state = Path.home() / ".local/share/steam-deck-wow"
    try:
        state.mkdir(parents=True, exist_ok=True)
        with (state / "setup.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise SetupError("Setup is already running in another terminal.") from error
            setup(args, state)
    except (KeyboardInterrupt, EOFError):
        print("\nSetup interrupted. Run the script again to resume.", file=sys.stderr)
        return 130
    except (SetupError, OSError, ValueError, urllib.error.URLError) as error:
        print(f"\nSetup needs attention: {error}", file=sys.stderr)
        return 1
    return 0


# Steam text KeyValues
_STEAM_ID64_BASE = 76561197960265728
_KV_TOKEN = re.compile(
    r'(?P<space>\s+)|(?P<comment>//[^\r\n]*)|'
    r'(?P<quoted>"(?:\\[\s\S]|[^"\\])*")|(?P<brace>[{}])|'
    r'(?P<condition>\[[^\[\]\r\n]+\])|(?P<bare>[^{}\s"\[\]\x00]+)'
)


@dataclass
class _SteamKV:
    key: str
    value: str | list["_SteamKV"]
    start: int
    value_start: int
    value_end: int


def _kv_decode(token):
    if token.lastgroup == "quoted":
        return re.sub(r'\\(["\\])', r'\1', token.group()[1:-1])
    return token.group()


def _parse_steam_kv(text: str) -> list[_SteamKV]:
    # Keep offsets so a change to one block never rewrites the rest of the file.
    stack: list[list[_SteamKV]] = [[]]
    key = None
    condition_allowed = False
    offset = int(text.startswith("\ufeff"))
    while offset < len(text):
        token = _KV_TOKEN.match(text, offset)
        if token is None or "\0" in token.group():
            raise ValueError(f"Invalid Steam KeyValues token at offset {offset}")
        offset = token.end()
        kind = token.lastgroup
        if kind in ("space", "comment"):
            continue
        raw = token.group()
        if kind == "condition":
            if not condition_allowed:
                raise ValueError(f"Unexpected Steam KeyValues condition at offset {token.start()}")
            condition_allowed = False
            continue
        if kind == "brace":
            if raw == "{" and key is not None:
                node = _SteamKV(_kv_decode(key), [], key.start(), token.start(), -1)
                stack[-1].append(node)
                stack.append(node.value)
                key = None
                condition_allowed = False
                continue
            if raw == "}" and key is None and len(stack) > 1:
                stack.pop()
                stack[-1][-1].value_end = offset
                condition_allowed = True
                continue
            raise ValueError(f"Unexpected Steam KeyValues brace at offset {token.start()}")
        if key is None:
            key = token
            condition_allowed = False
        else:
            stack[-1].append(_SteamKV(_kv_decode(key), _kv_decode(token), key.start(), token.start(), offset))
            key = None
            condition_allowed = True
    if key is not None or len(stack) != 1:
        raise ValueError("Incomplete Steam KeyValues file")
    return stack[0]


def _kv_child(nodes: list[_SteamKV], key: str, *, block: bool = False) -> _SteamKV | None:
    matches = [node for node in nodes if node.key.casefold() == key.casefold()]
    if len(matches) > 1:
        raise ValueError(f"Duplicate Steam KeyValues entry {key!r}")
    if not matches:
        return None
    node = matches[0]
    if block != isinstance(node.value, list):
        raise ValueError(f"Unexpected Steam KeyValues type for {key!r}")
    return node


def _kv_string(nodes: list[_SteamKV], key: str, default: str = "") -> str:
    node = _kv_child(nodes, key)
    return node.value if node else default


def read_steam_accounts(text: str) -> list[tuple[int, str, bool]]:
    """Read Steam account IDs, persona names and the most-recent flag from loginusers.vdf."""
    users = _kv_child(_parse_steam_kv(text), "users", block=True)
    if users is None:
        raise ValueError("Steam loginusers.vdf has no users block")
    accounts = []
    seen = set()
    for user in users.value:
        if not re.fullmatch(r"[0-9]{17}", user.key):
            continue
        account_id = int(user.key) - _STEAM_ID64_BASE
        if not 0 < account_id < 2**32:
            continue
        if account_id in seen or not isinstance(user.value, list):
            raise ValueError(f"Invalid Steam loginusers.vdf entry for account {account_id}")
        seen.add(account_id)
        persona = _kv_string(user.value, "PersonaName") or _kv_string(user.value, "AccountName")
        accounts.append((account_id, persona or str(account_id), _kv_string(user.value, "MostRecent") == "1"))
    return accounts


def _kv_quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _kv_indent(text: str, offset: int) -> str:
    line_start = max(text.rfind("\n", 0, offset), text.rfind("\r", 0, offset)) + 1
    prefix = text[line_start:offset]
    return prefix if not prefix.strip(" \t") else ""


def _kv_insertion(text: str, parent: _SteamKV, lines: list[tuple[int, str]]) -> tuple[int, int, str]:
    parent_indent = _kv_indent(text, parent.start)
    child_indent = next(
        (indent for child in parent.value if (indent := _kv_indent(text, child.start)).startswith(parent_indent)
         and len(indent) > len(parent_indent)),
        None,
    )
    unit = child_indent[len(parent_indent):] if child_indent else ("    " if parent_indent.endswith(" ") else "\t")
    first_break = re.search(r"\r\n|\n|\r", text)
    newline = first_break.group() if first_break else "\n"
    anchor = parent.value_start + 1
    addition = "".join(newline + parent_indent + unit * level + line for level, line in lines)
    if not re.match(r"[ \t]*(?:\r\n|\n|\r)", text[anchor:]):
        addition += newline + parent_indent
    return anchor, anchor, addition


def set_compat_tool(text: str, app_id: int, tool: str) -> str:
    """Set an app's Steam compatibility tool while retaining other config.vdf text."""
    if not 0 < app_id < 2**32 or not tool.strip() or any(c in tool for c in "\0\r\n"):
        raise ValueError("Invalid Steam compatibility tool or app ID")

    nodes = _parse_steam_kv(text)
    for key in ("InstallConfigStore", "Software", "Valve", "Steam"):
        steam = _kv_child(nodes, key, block=True)
        if steam is None:
            raise ValueError(f"Steam config.vdf has no {key} block")
        nodes = steam.value

    mapping = _kv_child(nodes, "CompatToolMapping", block=True)
    entry = _kv_child(mapping.value, str(app_id), block=True) if mapping else None
    fields = {"name": tool, "config": "", "priority": "250"}
    edits = []
    if entry is None:
        entry_lines = [(1, _kv_quote(str(app_id))), (1, "{")]
        entry_lines.extend((2, f'{_kv_quote(key)}\t\t{_kv_quote(value)}') for key, value in fields.items())
        entry_lines.append((1, "}"))
        if mapping is None:
            lines = [(1, '"CompatToolMapping"'), (1, "{")]
            lines.extend((level + 1, line) for level, line in entry_lines)
            lines.append((1, "}"))
            edits.append(_kv_insertion(text, steam, lines))
        else:
            edits.append(_kv_insertion(text, mapping, entry_lines))
    else:
        previous_tool = _kv_string(entry.value, "name")
        missing = []
        for key, value in fields.items():
            node = _kv_child(entry.value, key)
            if node is None:
                missing.append((1, f'{_kv_quote(key)}\t\t{_kv_quote(value)}'))
            elif key == "config" and previous_tool == tool:
                continue
            elif node.value != value:
                edits.append((node.value_start, node.value_end, _kv_quote(value)))
        if missing:
            edits.append(_kv_insertion(text, entry, missing))
    for start, end, replacement in sorted(edits, reverse=True):
        text = text[:start] + replacement + text[end:]
    return text


def custom_proton_tools(steam_root: Path) -> dict[str, str]:
    """Return installed Proton-compatible tool IDs and display names from their manifests."""
    directory = steam_root / "compatibilitytools.d"
    manifests = sorted([*directory.glob("*.vdf"), *directory.glob("*/compatibilitytool.vdf")])
    tools = {}
    for manifest in manifests:
        try:
            root = _kv_child(_parse_steam_kv(manifest.read_text(encoding="utf-8-sig")), "compatibilitytools", block=True)
            compat = _kv_child(root.value, "compat_tools", block=True) if root else None
            if compat is None:
                continue
            for node in compat.value:
                if not isinstance(node.value, list):
                    continue
                if "windows" not in _kv_string(node.value, "from_oslist", "windows").lower().split(","):
                    continue
                if "linux" not in _kv_string(node.value, "to_oslist", "linux").lower().split(","):
                    continue
                location = manifest.parent / _kv_string(node.value, "install_path", ".")
                if (location / "proton").is_file():
                    tools[node.key] = _kv_string(node.value, "display_name", node.key)
        except (OSError, ValueError):
            continue
    return tools


# WowUp release installation
WOWUP_EDITIONS = {
    "cf": ("WowUp.CF", "WowUp-CF", "WowUp (CurseForge)"),
    "wago": ("WowUp", "WowUp", "WowUp (Wago)"),
}
WOWUP_TAG = re.compile(r"v?(\d+\.\d+\.\d+(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?)\Z")
WOWUP_DOWNLOAD_HOSTS = {
    "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"
}


def wowup_open(url: str, hosts: set[str], accept: str = "*/*"):
    request = Request(url, headers={"User-Agent": "WoW-Deck-Setup", "Accept": accept})
    try:
        response = urlopen(request, timeout=60)
    except HTTPError as error:
        raise RuntimeError(f"GitHub returned HTTP {error.code} for {url}") from error
    except URLError as error:
        raise RuntimeError(f"Could not reach GitHub: {error.reason}") from error
    location = urlsplit(response.geturl())
    if location.scheme != "https" or location.hostname not in hosts:
        response.close()
        raise RuntimeError("GitHub redirected the WowUp download to an unexpected address.")
    return response


def wowup_asset_url(repository: str, tag: str, asset: dict) -> str:
    url = asset.get("browser_download_url", "")
    expected = f"https://github.com/WowUp/{repository}/releases/download/{tag}/{asset['name']}"
    if url != expected:
        raise RuntimeError("GitHub returned an unexpected WowUp release asset URL.")
    return url


def wowup_checksum(repository: str, release: dict, asset: dict) -> tuple[str, str]:
    digest = asset.get("digest")
    if isinstance(digest, str) and re.fullmatch(r"sha256:[a-fA-F0-9]{64}", digest):
        return "sha256", digest.split(":", 1)[1].lower()

    # Older GitHub releases predate asset digests. The upstream Electron
    # updater manifest names the same AppImage and publishes its SHA-512.
    manifest_pattern = re.compile(r"(?:latest|beta|alpha)-linux\.yml\Z")
    for manifest in release["assets"]:
        if not manifest_pattern.fullmatch(manifest.get("name", "")):
            continue
        url = wowup_asset_url(repository, release["tag_name"], manifest)
        with wowup_open(url, WOWUP_DOWNLOAD_HOSTS) as response:
            lines = response.read(65536).decode("utf-8").splitlines()
        entries = dict(line.split(":", 1) for line in lines if re.match(r"^(path|sha512):", line))
        if entries.get("path", "").strip().strip("\"'") != asset["name"]:
            continue
        try:
            checksum = base64.b64decode(entries.get("sha512", "").strip().strip("\"'"), validate=True)
        except (ValueError, binascii.Error):
            continue
        if len(checksum) == 64:
            return "sha512", checksum.hex()
    raise RuntimeError(f"No upstream checksum was available for {asset['name']}.")


def wowup_file_matches(path: Path, size: int, algorithm: str, checksum: str) -> bool:
    if not path.is_file() or path.stat().st_size != size:
        return False
    digest = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest() == checksum


def wowup_download(url: str, destination: Path, size: int, algorithm: str, checksum: str) -> None:
    temporary = None
    try:
        with wowup_open(url, WOWUP_DOWNLOAD_HOSTS) as response, tempfile.NamedTemporaryFile(
            dir=destination.parent, prefix=".wowup-", delete=False
        ) as stream:
            temporary = Path(stream.name)
            digest = hashlib.new(algorithm)
            written = 0
            for chunk in iter(lambda: response.read(1024 * 1024), b""):
                written += len(chunk)
                if written > size:
                    raise RuntimeError(f"The download exceeded the size published for {destination.name}.")
                digest.update(chunk)
                stream.write(chunk)
        if written != size or digest.hexdigest() != checksum:
            raise RuntimeError(f"The size or checksum did not match for {destination.name}.")
        temporary.chmod(0o755)
        os.replace(temporary, destination)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def install_wowup(edition: str, install_dir: Path, desktop: Path, version: str = "latest") -> Path:
    repository, asset_prefix, name = WOWUP_EDITIONS[edition]
    if version == "latest":
        endpoint = "latest"
    else:
        requested = WOWUP_TAG.fullmatch(version)
        if requested is None:
            raise ValueError("Enter a WowUp release version such as 2.25.5, or choose latest.")
        endpoint = f"tags/v{requested[1]}"

    api = f"https://api.github.com/repos/WowUp/{repository}/releases/{endpoint}"
    with wowup_open(api, {"api.github.com"}, "application/vnd.github+json") as response:
        release = json.load(response)
    tag = WOWUP_TAG.fullmatch(release.get("tag_name", ""))
    if tag is None or release.get("draft") or (version == "latest" and release.get("prerelease")):
        raise RuntimeError(f"GitHub did not return the requested published release for {name}.")

    asset_names = {
        f"{asset_prefix}-{tag[1]}.AppImage",
        f"{asset_prefix}-{tag[1]}-x86_64.AppImage",
    }
    candidates = [asset for asset in release.get("assets", []) if asset.get("name") in asset_names]
    if len(candidates) != 1 or not isinstance(candidates[0].get("size"), int) or candidates[0]["size"] <= 0:
        raise RuntimeError(f"No unique Linux x86-64 AppImage was found for {name} {tag[1]}.")

    asset = candidates[0]
    size = asset["size"]
    url = wowup_asset_url(repository, tag[0], asset)
    algorithm, checksum = wowup_checksum(repository, release, asset)
    install_dir = install_dir.expanduser().resolve()
    install_dir.mkdir(parents=True, exist_ok=True)
    appimage = install_dir / asset["name"]
    if wowup_file_matches(appimage, size, algorithm, checksum):
        appimage.chmod(0o755)
        print(f"Using verified {appimage.name}.")
    else:
        print(f"Downloading {appimage.name} ({size // (1024 * 1024)} MiB)...", flush=True)
        wowup_download(url, appimage, size, algorithm, checksum)

    write_desktop_launcher(
        desktop / f"{name}.desktop",
        name,
        [str(appimage), "--appimage-extract-and-run"],
        icon="system-software-install",
    )
    return appimage


# Bundled Battle.net artwork. The launcher icon comes from Faugus Launcher.
# https://github.com/Faugus/faugus-launcher/blob/1.18.2/assets/faugus-battlenet.png
_BATTLENET_ARTWORK = {
    'p': (
        "iVBORw0KGgoAAAANSUhEUgAAAlgAAAOECAMAAABKM78OAAABgFBMVEX////0+/95r+EIdNoAdOIA"
        "dOAAdN4ZWJMTOFwSNVcQNVcPNFgRMlIPMlMPME8OMFEQLUsOLU0OLEkPKkUNLEwNKUYNKEMNJkAM"
        "K0sMKUcMJkIMJT8MJD0LJ0YLJkQLJUILJEAMIjsLIjwLITkLIDgKIz8KIj0KITwKIDoLHzUKHzcK"
        "HjUKHTQKHDIJHzkJHjcJHTUJHDQJHDMKGzAJGzEJGjAJGi8JGS4IGzIIGjEIGTAIGS8IGS4JGCwI"
        "GC4IGC0IGCwIFywIFysHFywKFScIFikIFigIFSgHFisHFioHFikHFSoHFSkHFSgHFCgHFCcHFCYG"
        "FSYIEyQHEycHEyYHEyUHEyQHEiQHEiMGEiUGEyQGEiQFEiQGEiMHESIGESMGESIGESEGECIGECEG"
        "ECAGEB8HDyAGDyAGDx8GDx4FESIGDh8GDh4GDh0GDRwFDh4FDh0FDhwFDR0FDRwFDRsEDiEGDBoF"
        "DBsFDBoGDBkGCxkFCxoFCxkFCxgFChgFCheIvLDpAADBC0lEQVR42u39i2MUx5U3fg8CND1oNGqp"
        "pRkhDaCRRkijuzSgC1cDsQEbjLOBOF7Wl9jO2t51Eh7b78b72k7+9V9VX6u6z6k6VV09krOp51kn"
        "JjCS4ePvOX26urr2C18/k9ZPfP2Irb/l1w/x+h5e37H15s2f5fWttL4J19fA+oqtL/PrC2n9MV6f"
        "yesTaf2Bvj4krD+YrE+gxb7DPwor+8f5sriA35dvkpX9Jv65sP4Srvyfxw/pkv4U0T/vH3/6SYWl"
        "ZuaKzkrjyjkrc1WuNJUghtD6DKL1JYnWCGXpYVXpyiCunLNSqKoMlLEvfWxZhpZW1veVyqpV46q6"
        "uNKygsOKrEpr5ffQKqWrDK2vzqosKqyqXTlmhaqyMvV7s2WhS0NL1WpRyqGxrL+VllWr0JVtXJmw"
        "cqTKhScCMCNbMC1KaFEaLSeyVLDOgisgrtyzMjD1e5eLjsuallU5NJFlEVm1sq5syqBNXNFYGaoy"
        "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"
    ),
    '': (
        "iVBORw0KGgoAAAANSUhEUgAAA5gAAAGuCAMAAADCqlkWAAABgFBMVEX////v+f/d6/g0htEIdNkA"
        "dOMAdOAAdN4aYaYYPWASN1oQN1sVM1IQNVcQMlMPMlQQL04OL1ARKUQOK0kNLlANLEsNKUcNJ0MM"
        "K0sMKUcMJkIMJD8LJ0ULJUILJEAKIz4OIDcLIToKIj0KITwKITsKIDoKHzYKHTQJHzkJHjcJHTUL"
        "GzEJHDQJGzMJGzEJGi8IGzIIGjEIGS8IGS4KFyoIGC4IGC0IFy0IGCwIFywIFysIFikIFSgHFywH"
        "FisHFioHFikHFSoHFSkHFSgHFCgHFCcHFCYGFSgIEyUHEycHEyYHEyUHEyQIEiIHEiQHEiMHESIG"
        "EyUGEiUGEiQGEiMGESMGESIGESEFESQHECEGECIGECEHECAGECAGDyAGEB8HDx4GDx8GDx4FDx8H"
        "Dh0GDh8GDh4GDh0GDR0FDh4FDh0FDR4FDR0GDRwFDhwFDRwFDRsEDRwGDBoFDBsFDBoFDBkGCxkF"
        "CxoFCxkFCxgEDBkFChkFChgFChcDChoEChVMO9mqAACS0klEQVR42u3di2MTx703fGETrBUreb3C"
        "kq31RZIvsi2DABtisIEEAi/FCdAA6Sk09CQ9b9vw0CbP2z4nyXnac/719zezt5ndue+sJJPOOQXi"
        "m2zZH39/85vZ2cpP4vFjMv5uPv6mM37gje9LGX/B48/E+NOUjL+oD/Uv9wfpEH5zCvwQ/P2n4uNn"
        "1fEPg/HPqRqVUkla8FiCxClEaFGqHaAl6Rwfzn+ccZsVockxiByDx/dn02FhpsV9lqJzqm1OK8zC"
        "MVkQpC2K799/gBSNkRb0WYLOf9lUh1nUZCGRdjC+/wVZNCJawKd1nf9nPDbPKs2KhdK1gEgLGEOO"
        "9n/E/ziuMX6ixjxt65xam1MAs4hJc5F2OJ4xgRPiaubTQOdEcH6osVkxMzkBke9jj1PG8FvpmBKn"
        "Jj7Ho3NKbU4WZikm7Yl8H3scv8RvxzrGxlSfp7ZOA5s//oumOUwzkuP3OOUE7WK169OApz2c/7Kp"
        "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"
        "mAKKHwfRaHgAAAAASUVORK5CYII="
    ),
    '_icon': (
        "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"
        "MDAJzZa+AAAAAElFTkSuQmCC"
    ),
}


def install_artwork(grid: Path, app_id: int) -> Path:
    import base64
    import os
    import tempfile

    grid = grid.resolve()
    grid.mkdir(parents=True, exist_ok=True)
    for suffix, payload in _BATTLENET_ARTWORK.items():
        name = f"{app_id}{suffix}"
        target = grid / f"{name}.png"
        extensions = (".png",) if suffix == "_icon" else (".png", ".jpg", ".jpeg", ".webp")
        if any((grid / f"{name}{extension}").is_file() for extension in extensions):
            continue
        with tempfile.NamedTemporaryFile(dir=grid, delete=False) as temp:
            temp_path = Path(temp.name)
            try:
                temp.write(base64.b64decode(payload, validate=True))
                temp.close()
                os.replace(temp_path, target)
            finally:
                temp_path.unlink(missing_ok=True)
    return grid / f"{app_id}_icon.png"


if __name__ == "__main__":
    raise SystemExit(main())
STEAM_DECK_WOW_EMBEDDED_PYTHON

"$python_command" -I "$payload_path" "$@"
