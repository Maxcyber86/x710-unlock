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
      --build-only     Only build the helper binaries (-> ./x710-prebuilt), then exit
      --prebuilt DIR   Use prebuilt helper binaries from DIR (no gcc needed on target)
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

### Which port on a dual/quad-port card?

Both ports of a multi-port X710 (e.g. a DA2's two ports, PCI functions `.0` and `.1`)
**share the same physical EEPROM**. The patch therefore has the same effect regardless of
which port you go through, and there is no benefit to using the second port.

To avoid any ambiguity the script **always uses the first port** (`.0`) of a card
automatically. If you pass a second port via `-i` (e.g. `-i eth3`), it is normalized back
to the first port of that same card. When several **different** X710 cards are present, the
script asks which *card* to use — but never which port.

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

## Unraid (7.3+)

The script detects Unraid automatically (`/etc/unraid-version`) and adapts.

**One-click on Unraid too** — if no compiler is present (the norm on Unraid 7, where the
former *NerdTools* plugin no longer works), the script **automatically downloads the
prebuilt helper binaries** from this repo's `x710-prebuilt/` folder and validates them
(ELF magic check). So the same single command works:

```bash
curl -fsSL https://raw.githubusercontent.com/Maxcyber86/x710-unlock/main/x710-unlock.sh -o x710-unlock.sh
sudo bash x710-unlock.sh --dry-run
sudo bash x710-unlock.sh
```

> Requires that `x710-prebuilt/x710_read`, `x710_write`, `x710_csum` (x86_64 ELF) are
> present in the repo. Maintainers: build them once with `--build-only` on any Linux and
> commit them (see "Maintainer" below).

**Manual / offline fallback** (no internet on the server, or you don't trust the repo
binaries — compile yourself):

```bash
# On any other Linux (e.g. an Ubuntu live USB):
sudo bash x710-unlock.sh --build-only      # -> creates ./x710-prebuilt/

# Copy that folder to the server (e.g. /boot/x710-prebuilt), then on Unraid:
bash x710-unlock.sh --prebuilt /boot/x710-prebuilt
```

Other Unraid notes:

- **Driver in use.** The `i40e` driver often has Docker bridges, VLANs or VM/vhost
  attached, which prevents `modprobe -r i40e`. Before the real run, stop the Docker
  service and any VMs that bind the card. The script checks the module refcount and warns.
- **Self-cut protection (bridge/vhost aware).** Reloading the driver drops the card and
  every interface stacked on top of it. The script resolves the full interface hierarchy
  (bridges like `br0`, `vhost`/macvtap like `vhost2`, VLANs, bonds) down to the physical
  ports and also matches sibling ports on the same PCI card (e.g. eth2 **and** eth3 of a
  DA2). If your SSH session or the default route reaches the card **through any of these**,
  it aborts. On Unraid the default route typically runs over `vhost2`/`br0` which sits on
  the X710 — exactly this indirect case is now caught. To proceed you must be **physically
  at the console** and restart with `CONSOLE_OVERRIDE=1` prepended; there is no interactive
  bypass (too dangerous remotely). **Best practice: patch over a path NOT on this card**
  (onboard NIC, IPMI, or Intel AMT, which survives the reload).

**Secure Boot** must be off (see Requirements) — relevant on bare-metal Unraid too.

### Maintainer: providing the prebuilt binaries

The auto-download expects three x86_64 ELF files in `x710-prebuilt/`. To (re)generate them:

```bash
# On any x86_64 Linux with gcc:
sudo bash x710-unlock.sh --build-only      # creates ./x710-prebuilt/
git add x710-prebuilt/x710_read x710-prebuilt/x710_write x710-prebuilt/x710_csum
git commit -m "Add prebuilt helper binaries for Unraid auto-download"
git push
```

Note: `.gitignore` ignores loose `x710_read`/`x710_write`/`x710_csum` elsewhere, but the
copies inside `x710-prebuilt/` are force-added by the path above and tracked normally.





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
      --build-only     Nur die Hilfsprogramme bauen (-> ./x710-prebuilt), dann beenden
      --prebuilt DIR   Vorgebaute Hilfsprogramme aus DIR nutzen (kein gcc noetig)
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

### Welcher Port bei Dual-/Quad-Port-Karten?

Beide Ports einer mehrportigen X710 (z. B. die zwei Ports einer DA2, PCI-Funktionen `.0`
und `.1`) **teilen sich dasselbe physische EEPROM**. Der Patch wirkt daher identisch, egal
ueber welchen Port man geht - der zweite Port bringt keinen Vorteil.

Um jede Mehrdeutigkeit zu vermeiden, nutzt das Script **automatisch immer den ersten Port**
(`.0`) einer Karte. Gibt man per `-i` einen zweiten Port an (z. B. `-i eth3`), wird er auf
den ersten Port derselben Karte zurueckgesetzt. Sind mehrere **verschiedene** X710-Karten
vorhanden, fragt das Script, welche *Karte* genutzt werden soll - aber nie, welcher Port.

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

## Unraid (7.3+)

Das Script erkennt Unraid automatisch (`/etc/unraid-version`) und passt sich an.

**One-Click auch auf Unraid** — ist kein Compiler vorhanden (Normalfall auf Unraid 7, wo
das fruehere *NerdTools*-Plugin nicht mehr funktioniert), **laedt das Script die
vorgebauten Hilfsprogramme automatisch** aus dem `x710-prebuilt/`-Ordner dieses Repos und
validiert sie (ELF-Magic-Pruefung). Damit funktioniert derselbe Einzelbefehl:

```bash
curl -fsSL https://raw.githubusercontent.com/Maxcyber86/x710-unlock/main/x710-unlock.sh -o x710-unlock.sh
sudo bash x710-unlock.sh --dry-run
sudo bash x710-unlock.sh
```

> Setzt voraus, dass `x710-prebuilt/x710_read`, `x710_write`, `x710_csum` (x86_64 ELF) im
> Repo liegen. Maintainer: einmalig mit `--build-only` auf einem beliebigen Linux bauen
> und committen (siehe "Maintainer" unten).

**Manueller / Offline-Fallback** (kein Internet am Server, oder du willst den Repo-Binaries
nicht vertrauen — selbst kompilieren):

```bash
# Auf einem beliebigen anderen Linux (z. B. Ubuntu Live-USB):
sudo bash x710-unlock.sh --build-only      # -> erzeugt ./x710-prebuilt/

# Diesen Ordner auf den Server kopieren (z. B. /boot/x710-prebuilt), dann auf Unraid:
bash x710-unlock.sh --prebuilt /boot/x710-prebuilt
```

Weitere Unraid-Hinweise:

- **Treiber in Benutzung.** Am `i40e`-Treiber haengen oft Docker-Bridges, VLANs oder
  VM/vhost, was `modprobe -r i40e` verhindert. Vor dem echten Lauf den Docker-Dienst und
  VMs stoppen, die die Karte binden. Das Script prueft den Modul-Refcount und warnt.
- **Self-Cut-Schutz (Bridge/vhost-bewusst).** Der Treiber-Reload wirft die Karte ab -
  samt aller darauf aufsitzenden Interfaces. Das Script loest die komplette Hierarchie
  auf (Bridges wie `br0`, `vhost`/macvtap wie `vhost2`, VLANs, Bonds) bis zu den
  physischen Ports und erkennt auch Geschwister-Ports derselben PCI-Karte (z.B. eth2
  **und** eth3 einer DA2). Fuehrt deine SSH-Sitzung oder die Default-Route **ueber
  irgendeinen dieser Wege** auf die Karte, bricht es ab. Auf Unraid laeuft die
  Default-Route typischerweise ueber `vhost2`/`br0`, das auf der X710 sitzt - genau dieser
  indirekte Fall wird jetzt erkannt. Zum Fortfahren musst du **physisch an der Konsole**
  sitzen und mit vorangestelltem `CONSOLE_OVERRIDE=1` neu starten; es gibt keinen
  interaktiven Bypass (remote zu gefaehrlich). **Empfehlung: ueber einen Pfad patchen, der
  NICHT auf dieser Karte liegt** (Onboard-NIC, IPMI oder Intel AMT, das den Reload
  ueberlebt).

**Sicherer Start (Secure Boot)** muss aus sein (siehe Voraussetzungen) — auch auf
Bare-Metal-Unraid relevant.

### Maintainer: vorgebaute Binaries bereitstellen

Der Auto-Download erwartet drei x86_64-ELF-Dateien in `x710-prebuilt/`. Zum (Neu-)Erzeugen:

```bash
# Auf einem beliebigen x86_64-Linux mit gcc:
sudo bash x710-unlock.sh --build-only      # erzeugt ./x710-prebuilt/
git add x710-prebuilt/x710_read x710-prebuilt/x710_write x710-prebuilt/x710_csum
git commit -m "Add prebuilt helper binaries for Unraid auto-download"
git push
```

Hinweis: Die `.gitignore` ignoriert lose `x710_read`/`x710_write`/`x710_csum` an anderen
Orten, aber die Kopien in `x710-prebuilt/` werden ueber den obigen Pfad explizit
hinzugefuegt und normal versioniert.

## Lizenz

MIT. Siehe `LICENSE`. Ohne jede Gewähr.
