# x710-unlock

**One-Click SFP+ Module Qualification Unlock für Intel X710 / XL710 Netzwerkkarten.**

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

---

## ⚠️ Warnung

Dieses Script **schreibt ins EEPROM** deiner Netzwerkkarte. Theoretisch besteht ein
Brick-Risiko. Vor jedem Patch wird automatisch ein vollständiges EEPROM-Backup
unter `~/x710-unlock-backups/` abgelegt. Nutzung **auf eigene Gefahr**.

Im Falle eines Bricks lässt sich die Karte mit einem CH341A-Programmer und einem
EEPROM-Backup wiederherstellen.

---

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

---



- **Linux** (das Verfahren nutzt den `i40e`-Treiber und `ethtool`-ioctls — funktioniert
  nicht unter Windows oder WSL2). Ein Ubuntu Live-USB genügt vollkommen.
- Die Karte muss mit dem `i40e`-Treiber laufen (Standard bei X710).
- `gcc`, `ethtool`, `pciutils`, `iproute2` — werden bei Bedarf automatisch installiert.
- root / sudo.

---

## One-Click-Nutzung

Auf dem Linux-System (z. B. Ubuntu Live-USB), Terminal öffnen:

```bash
curl -fsSL https://raw.githubusercontent.com/Maxcyber86/x710-unlock/main/x710-unlock.sh -o x710-unlock.sh
sudo bash x710-unlock.sh
```

Oder als Einzeiler (mit interaktiver Bestätigung):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Maxcyber86/x710-unlock/main/x710-unlock.sh)
```

Das Script:

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

Danach: **komplett herunterfahren, 30 s vom Strom, neu starten.** Die Karte akzeptiert
nun beliebige SFP+-Module.

---

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

---

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

---

## Getestete Hardware

- Intel X710-DA2 (auch Lenovo-OEM-Variante, nach Crossflash auf Intel-Generic)
- NVM 9.56 / 9.57, EFI 5.0.33 / 5.0.52
- Generische 10G-T-SFP+ Module (Broadcom-PHY)

Sollte auf allen X710/XL710 (DeviceID `8086:1572`) funktionieren. Andere DeviceIDs
(X722 etc.) sind nicht getestet — die DeviceID lässt sich oben im Script anpassen.

---

## Lizenz

MIT. Siehe `LICENSE`. Ohne jede Gewähr.
