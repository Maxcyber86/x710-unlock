# x710-unlock

**One-Click SFP+ Module Qualification Unlock for Intel X710 / XL710 network cards.**

🇬🇧 [English](#english) · 🇩🇪 [Deutsch](#deutsch)

---

<a name="english"></a>
# 🇬🇧 English

Intel X710-based cards (and many OEM variants from Dell, Lenovo, HP …) reject
"non-qualified" SFP+ modules — especially generic 10G-T-SFP+ modules
(RJ45 copper with a Broadcom PHY). This script disables the module-qualification
check directly in the card's EEPROM, so that arbitrary SFP+ modules are accepted.

It clears **bit 11** in all four PHY records of the NVM EEPROM and then updates the
NVM checksum. The patch is persistent (survives reboots and even driver/OS changes)
and fully reversible.

> Based on the reverse-engineering work of **Wesley Terpstra** and
> **[sretalla/xl710-unlocker](https://github.com/sretalla/xl710-unlocker)**.
> This repo automates the entire procedure and adds robust auto-detection, a
> driver-reload pattern to work around the i40e NVM lock, and the correct
> checksum magic.

## ⚠️ Warning

This script **writes to the EEPROM** of your network card. There is a theoretical
brick risk. A full EEPROM backup is automatically saved to `~/x710-unlock-backups/`
before any patch. Use **at your own risk**.

In case of a brick, the card can be recovered with a CH341A programmer and an
EEPROM backup.

## 🚀 Quick Start (recommended)

On a Linux system (e.g. an Ubuntu live USB), open a terminal:

```bash
# 1. Fetch the script from GitHub
curl -fsSL https://raw.githubusercontent.com/Maxcyber86/x710-unlock/main/x710-unlock.sh -o x710-unlock.sh

# 2. Analyze first - this is guaranteed to write NOTHING
sudo bash x710-unlock.sh --dry-run

# 3. If the analysis looks plausible (4 PHYs, 0x6b0c -> 0x630c), run it for real:
sudo bash x710-unlock.sh

# 4. Then: shut down completely, unplug power for 30 s, restart.
```

That's it. After the restart, the card accepts arbitrary SFP+ modules.

## Requirements

- **Linux** (the procedure uses the `i40e` driver and `ethtool` ioctls — it does not
  work on Windows or WSL2). An Ubuntu live USB is perfectly sufficient.
- **Secure Boot must be disabled** in the BIOS/UEFI for the duration of the work, if it
  is enabled. The script repeatedly unloads and reloads the `i40e` kernel module; with
  Secure Boot active, reloading unsigned/out-of-tree modules can be blocked, which breaks
  the driver-reload workaround. You can re-enable Secure Boot afterwards.
- The card must run with the `i40e` driver (default for X710).
- `gcc`, `ethtool`, `pciutils`, `iproute2` — installed automatically if missing.
- root / sudo.

## Options

```
sudo bash x710-unlock.sh [OPTIONS]

  -i, --iface <name>   Specify interface explicitly (instead of auto-detection)
  -y, --yes            No prompts (fully automatic — use with caution!)
      --dry-run        Analyze only, write nothing
      --restore        Revert the patch (set bit 11 again)
  -h, --help           Show help
```

### Examples

```bash
# Safely preview what would happen:
sudo bash x710-unlock.sh --dry-run

# Fully automatic on a specific interface:
sudo bash x710-unlock.sh -i enp4s0f0np0 --yes

# Revert the patch:
sudo bash x710-unlock.sh -i enp4s0f0np0 --restore
```

## What the script does

1. installs missing dependencies,
2. compiles the required helper programs,
3. auto-detects the X710 interface,
4. scans the EEPROM and locates the 4 PHY records,
5. reads the current values and computes the new ones,
6. creates a full EEPROM backup,
7. asks for confirmation,
8. patches all 4 registers — **with a driver reload after each write** (against the i40e lock),
9. updates the NVM checksum,
10. verifies the result.

## How it works

Intel X710 cards have four internal PHY lanes. The NVM EEPROM contains four
corresponding configuration records, each introduced by the marker value `0x000b`.
In the word immediately after the marker (marker + 1) sits a register whose
**bit 11 (`0x0800`)** enables SFP module qualification.

When bit 11 is set, the firmware checks inserted SFP+ modules against a vendor
whitelist and rejects unknown ones. Clearing bit 11 in all four records and
recomputing the NVM checksum disables the check.

The script auto-detects the offset and stride of the records (these vary by NVM
version), so no hard-coded addresses are needed.

### The i40e NVM lock

The `i40e` driver often locks further NVM operations after an EEPROM access
(`ioctl: No such process`). The script works around this by reloading the driver
before **every** read/write access (`modprobe -r i40e && modprobe i40e`).

### Checksum magic

The NVM checksum recalc operation needs the ethtool magic
`(devid << 16) | ((CSUM | SA) << 8)` with `CSUM = 0x8` and `SA = 0x3`, giving e.g.
`0x15720b00` for the X710. The script tries this variant first and falls back to
`CSUM` alone if needed.

## Tested hardware

- Intel X710-DA2 (including the Lenovo OEM variant, after crossflashing to Intel-generic)
- NVM 9.56 / 9.57, EFI 5.0.33 / 5.0.52
- Generic 10G-T-SFP+ modules (Broadcom PHY)

Should work on all X710/XL710 (DeviceID `8086:1572`). Other DeviceIDs (X722 etc.)
are untested — the DeviceID can be adjusted at the top of the script.

## License

MIT. See `LICENSE`. Without any warranty.

---

<a name="deutsch"></a>
# 🇩🇪 Deutsch

Intel X710-basierte Karten (und viele OEM-Varianten von Dell, Lenovo, HP …) lehnen
"nicht zertifizierte" SFP+-Module ab — insbesondere generische 10G-T-SFP+-Module
(RJ45-Kupfer mit Broadcom-PHY). Dieses Script deaktiviert die Module-Qualification-Sperre
direkt im EEPROM der Karte, sodass beliebige SFP+-Module akzeptiert werden.

Es löscht dazu **Bit 11** in allen vier PHY-Records des NVM-EEPROM und aktualisiert
anschließend die NVM-Checksumme. Der Patch ist persistent (übersteht Reboots und
sogar Treiber-/OS-Wechsel) und vollständig reversibel.

> Basiert auf der Reverse-Engineering-Arbeit von **Wesley Terpstra** und
> **[sretalla/xl710-unlocker](https://github.com/sretalla/xl710-unlocker)**.
> Dieses Repo automatisiert den kompletten Ablauf und ergänzt robuste
> Auto-Detection, ein Treiber-Reload-Pattern gegen den i40e-NVM-Lock und die
> korrekte Checksum-Magic.

## ⚠️ Warnung

Dieses Script **schreibt ins EEPROM** deiner Netzwerkkarte. Theoretisch besteht ein
Brick-Risiko. Vor jedem Patch wird automatisch ein vollständiges EEPROM-Backup
unter `~/x710-unlock-backups/` abgelegt. Nutzung **auf eigene Gefahr**.

Im Falle eines Bricks lässt sich die Karte mit einem CH341A-Programmer und einem
EEPROM-Backup wiederherstellen.

## 🚀 Quick Start (empfohlen)

Auf einem Linux-System (z. B. Ubuntu Live-USB), Terminal öffnen:

```bash
# 1. Script von GitHub holen
curl -fsSL https://raw.githubusercontent.com/Maxcyber86/x710-unlock/main/x710-unlock.sh -o x710-unlock.sh

# 2. Erst gefahrlos analysieren - schreibt garantiert NICHTS
sudo bash x710-unlock.sh --dry-run

# 3. Sieht die Analyse plausibel aus (4 PHYs, 0x6b0c -> 0x630c)? Dann echt laufen lassen:
sudo bash x710-unlock.sh

# 4. Danach: komplett herunterfahren, 30 s Strom weg, neu starten.
```

Das war's. Die Karte akzeptiert nach dem Neustart beliebige SFP+-Module.

## Voraussetzungen

- **Linux** (das Verfahren nutzt den `i40e`-Treiber und `ethtool`-ioctls — funktioniert
  nicht unter Windows oder WSL2). Ein Ubuntu Live-USB genügt vollkommen.
- **Sicherer Start (Secure Boot) muss im BIOS/UEFI deaktiviert sein** für die Dauer der
  Arbeit, falls er aktiviert ist. Das Script entlädt und lädt das `i40e`-Kernelmodul
  wiederholt neu; bei aktivem Secure Boot kann das Nachladen unsignierter/out-of-tree
  Module blockiert werden, was den Treiber-Reload-Workaround verhindert. Nach getaner
  Arbeit kann Secure Boot wieder aktiviert werden.
- Die Karte muss mit dem `i40e`-Treiber laufen (Standard bei X710).
- `gcc`, `ethtool`, `pciutils`, `iproute2` — werden bei Bedarf automatisch installiert.
- root / sudo.

## Optionen

```
sudo bash x710-unlock.sh [OPTIONEN]

  -i, --iface <name>   Interface explizit angeben (statt Auto-Detection)
  -y, --yes            Keine Rückfragen (vollautomatisch — mit Vorsicht!)
      --dry-run        Nur analysieren, nichts schreiben
      --restore        Patch rückgängig machen (Bit 11 wieder setzen)
  -h, --help           Hilfe anzeigen
```

### Beispiele

```bash
# Erst gefahrlos schauen, was passieren würde:
sudo bash x710-unlock.sh --dry-run

# Vollautomatisch auf einem bestimmten Interface:
sudo bash x710-unlock.sh -i enp4s0f0np0 --yes

# Patch rückgängig machen:
sudo bash x710-unlock.sh -i enp4s0f0np0 --restore
```

## Was das Script macht

1. installiert fehlende Abhängigkeiten,
2. kompiliert die nötigen Hilfsprogramme,
3. erkennt das X710-Interface automatisch,
4. scannt das EEPROM und lokalisiert die 4 PHY-Records,
5. liest die aktuellen Werte und berechnet die neuen,
6. legt ein vollständiges EEPROM-Backup an,
7. fragt nach Bestätigung,
8. patcht alle 4 Register — **mit Treiber-Reload nach jedem Write** (gegen den i40e-Lock),
9. aktualisiert die NVM-Checksumme,
10. verifiziert das Ergebnis.

## Wie es funktioniert

Intel X710-Karten haben vier interne PHY-Lanes. Im NVM-EEPROM existieren vier
zugehörige Konfigurationsrecords, jeweils eingeleitet durch den Marker-Wert `0x000b`.
Im Wort direkt dahinter (Marker + 1) sitzt ein Register, dessen **Bit 11 (`0x0800`)**
die SFP-Module-Qualifikation aktiviert.

Ist Bit 11 gesetzt, prüft die Firmware eingesteckte SFP+-Module gegen eine
Hersteller-Whitelist und lehnt unbekannte ab. Wird Bit 11 in allen vier Records
gelöscht und die NVM-Checksumme neu berechnet, ist die Prüfung deaktiviert.

Das Script erkennt Offset und Schrittweite der Records automatisch (diese variieren je
nach NVM-Version), sodass keine fest verdrahteten Adressen nötig sind.

### Der i40e-NVM-Lock

Der `i40e`-Treiber sperrt nach EEPROM-Zugriffen oft weitere NVM-Operationen
(`ioctl: No such process`). Das Script umgeht das, indem es den Treiber vor **jedem**
Lese-/Schreibzugriff neu lädt (`modprobe -r i40e && modprobe i40e`).

### Checksum-Magic

Die NVM-Checksum-Recalc-Operation benötigt die ethtool-Magic
`(devid << 16) | ((CSUM | SA) << 8)` mit `CSUM = 0x8` und `SA = 0x3`, ergibt
z. B. `0x15720b00` für die X710. Das Script versucht diese Variante zuerst und fällt
bei Bedarf auf `CSUM` allein zurück.

## Getestete Hardware

- Intel X710-DA2 (auch Lenovo-OEM-Variante, nach Crossflash auf Intel-Generic)
- NVM 9.56 / 9.57, EFI 5.0.33 / 5.0.52
- Generische 10G-T-SFP+ Module (Broadcom-PHY)

Sollte auf allen X710/XL710 (DeviceID `8086:1572`) funktionieren. Andere DeviceIDs
(X722 etc.) sind nicht getestet — die DeviceID lässt sich oben im Script anpassen.

## Lizenz

MIT. Siehe `LICENSE`. Ohne jede Gewähr.
