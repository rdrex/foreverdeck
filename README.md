# ForeverDeck

ForeverDeck sets up Battle.net and World of Warcraft utilities on Steam Deck. It adds Battle.net to your Steam library with a portrait cover, a wide cover, and an icon, so you can launch it from Gaming Mode. You can also add desktop shortcuts for WowUp and Zygor.

## Install on Steam Deck

Start in **Desktop Mode** with an internet connection and Steam signed in. Run the installer from Konsole as your regular Deck user.

1. [Open `steam-deck-wow.sh`](./steam-deck-wow.sh) and save it to **Downloads**. On GitHub, use **Download raw file**. If the script opens as text on GitHub Pages, save the link as `steam-deck-wow.sh`.
2. Open **Konsole** and run the following command.

   ```bash
   bash ~/Downloads/steam-deck-wow.sh
   ```

3. Choose your WoW editions and any addon managers you want. Close running Steam games when prompted so the installer can restart Steam and update your library.
4. Complete Battle.net setup with its default location. When prompted, exit Battle.net from its system tray menu and return to Konsole.
5. Sign in when Battle.net reopens. Use **Game Version → Install** for each edition on the checklist. **WoW: Forever** may have its own page in the launcher. [Blizzard’s WoW: Forever setup guide](https://news.blizzard.com/en-us/article/24315643/return-to-azeroth-in-world-of-warcraft-forever)

The Bash file includes the full setup program. It uses Python 3.10 or newer when available and otherwise downloads a checksum-verified portable copy into `~/.local/share/steam-deck-wow/runtime/`. Setup runs without `sudo`. [Portable Python release](https://github.com/astral-sh/python-build-standalone/releases/tag/20261026)

## Play in Gaming Mode

Once your game finishes downloading, open **Library → Non-Steam → Battle.net**. Choose your installed edition in Battle.net and select **Play**.

The setup menu includes WoW: Forever, Retail, Classic progression, Classic Era, Burning Crusade Classic Anniversary, and the Retail PTR. Battle.net handles the downloads and shows the editions available to your account.

## Addon managers

- **WowUp** — Choose the CurseForge edition, the Wago edition, or both. Press Enter for the latest stable release or enter a specific release version. After WoW finishes downloading, open your WowUp desktop shortcut. If a game is missing, use **Options → Clients → Add New** and select its game executable. ForeverDeck prints the default WoW folder in Konsole. [WowUp client setup](https://wowup.io/guide/options/wow-clients)
- **Zygor** — Add a desktop shortcut to the Members Area, or download the Windows installer from your Zygor account and give ForeverDeck its local `.exe` path. Exit Battle.net fully before opening the installed Zygor client. [Zygor download instructions](https://zygorguides.com/support/manual/downloading)

## Troubleshooting

- **The installer window doesn’t open.** In Desktop Mode, open **Steam → Library → Battle.net → Play**. If Steam reports a compatibility tool error, check **Library → Tools** for Proton Experimental and its Steam Linux Runtime.
- **Setup was interrupted.** Run the same command again to resume. ForeverDeck stores setup files under `~/.local/share/steam-deck-wow/` and backs up changed Steam configuration files in the account’s `steam-backups/` folder.
- **WowUp can’t find a custom install.** In Battle.net, select the gear next to **Play** and open **Show in Explorer** to check the game’s location. Wine’s `Z:\` drive normally maps to `/` on SteamOS.

## Testing and credits

The Python bootstrap, Steam shortcut creation, artwork, and reruns were tested with simulated installs. A live Steam Deck run, including Gaming Mode and Zygor setup, still needs verification.

ForeverDeck is an independent project. The bundled Battle.net icon comes from [Faugus Launcher](https://github.com/Faugus/faugus-launcher/blob/1.18.2/assets/faugus-battlenet.png).
