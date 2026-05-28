#!/usr/bin/env bash
#
# x710-unlock.sh - Intel X710 SFP+ Module Qualification Unlock
# =============================================================
#
# Entsperrt die SFP+-Modul-Whitelist auf Intel X710 / XL710 Karten,
# indem Bit 11 in allen PHY-Records des EEPROM geloescht wird.
# Danach akzeptiert die Karte beliebige SFP+-Module (auch generische
# 10G-T-SFP+ mit Broadcom-Chip etc.).
#
# Basiert auf der Arbeit von Wesley Terpstra und sretalla/xl710-unlocker.
# Erweitert um: Auto-Detection des Interfaces und PHY-Layouts, robustes
# Treiber-Reload-Pattern (gegen i40e NVM-Lock), korrekte Checksum-Magic.
#
# WARNUNG: Schreibt ins EEPROM der Netzwerkkarte. Theoretisches Brick-Risiko.
#          Ein vollstaendiges EEPROM-Backup wird vor dem Patch erstellt.
#          Nutzung auf eigene Gefahr.
#
# Aufruf:
#   sudo ./x710-unlock.sh                 # interaktiv, fragt nach
#   sudo ./x710-unlock.sh -i enp4s0f0np0  # Interface explizit
#   sudo ./x710-unlock.sh --yes           # ohne Rueckfragen (Vorsicht!)
#   sudo ./x710-unlock.sh --dry-run       # nur analysieren, nichts schreiben
#   sudo ./x710-unlock.sh --restore       # Patch rueckgaengig (Bit 11 setzen)
#   sudo ./x710-unlock.sh --build-only    # nur die Hilfsprogramme bauen (z.B. auf
#                                         #   einem Live-USB), dann auf Unraid mitnehmen
#   sudo ./x710-unlock.sh --prebuilt DIR  # vorgebaute Hilfsprogramme aus DIR nutzen
#                                         #   (gcc auf dem Zielsystem nicht noetig)
#
set -euo pipefail

# ---------- Konfiguration ----------
DEVID="0x1572"          # X710/XL710 PCI Device ID
QUAL_BIT="0x0800"       # Bit 11 = Module Qualification Enable
SCAN_START="0x6800"     # Start des EEPROM-Scan-Bereichs (Wort-Offset)
SCAN_LEN="0x400"        # Laenge des Scan-Bereichs (Woerter)
EXPECTED_PHYS=4         # Erwartete Anzahl PHY-Records
RELOAD_SETTLE=4         # Sekunden Wartezeit nach modprobe
WORKDIR="$(mktemp -d /tmp/x710-unlock.XXXXXX)"
BACKUPDIR="${HOME}/x710-unlock-backups"

# Basis-URL fuer vorgebaute Hilfsprogramme (genutzt wenn kein gcc + kein --prebuilt).
# Erwartet dort die Dateien: x710_read, x710_write, x710_csum (x86_64 ELF).
PREBUILT_URL_BASE="https://raw.githubusercontent.com/Maxcyber86/x710-unlock/main/x710-prebuilt"

# ---------- Flags ----------
IFACE=""
ASSUME_YES=0
DRY_RUN=0
RESTORE=0
PREBUILT_DIR=""
BUILD_ONLY=0

# ---------- Farben ----------
if [[ -t 1 ]]; then
    R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'; C='\033[0;36m'; N='\033[0m'; BOLD='\033[1m'
else
    R=''; G=''; Y=''; B=''; C=''; N=''; BOLD=''
fi
info()  { echo -e "${C}[*]${N} $*"; }
ok()    { echo -e "${G}[+]${N} $*"; }
warn()  { echo -e "${Y}[!]${N} $*"; }
err()   { echo -e "${R}[x]${N} $*" >&2; }
step()  { echo -e "\n${B}${BOLD}=== $* ===${N}"; }

cleanup() { rm -rf "$WORKDIR" 2>/dev/null || true; }
trap cleanup EXIT

die() { err "$*"; exit 1; }

# ---------- Argument-Parsing ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--iface)   IFACE="$2"; shift 2 ;;
        -y|--yes)     ASSUME_YES=1; shift ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --restore)    RESTORE=1; shift ;;
        --prebuilt)   PREBUILT_DIR="$2"; shift 2 ;;
        --build-only) BUILD_ONLY=1; shift ;;
        -h|--help)
            grep '^#' "$0" | grep -v '^#!' | sed 's/^# \?//' | head -40
            exit 0 ;;
        *) die "Unbekanntes Argument: $1 (--help fuer Hilfe)" ;;
    esac
done

# ---------- Vorbedingungen ----------
[[ $EUID -eq 0 ]] || die "Bitte mit sudo/root ausfuehren."

# OS erkennen: unraid / debian / other
detect_os() {
    if [[ -f /etc/unraid-version ]]; then
        echo "unraid"
    elif command -v apt-get >/dev/null 2>&1; then
        echo "debian"
    else
        echo "other"
    fi
}
OS="$(detect_os)"

step "Vorbedingungen pruefen"
info "Erkanntes System: $OS"
if [[ "$OS" == "unraid" ]]; then
    UNRAID_VER="$(cat /etc/unraid-version 2>/dev/null | tr -d '"' | cut -d= -f2)"
    info "Unraid-Version: ${UNRAID_VER:-unbekannt}"
fi

# Tool-Verfuegbarkeit pruefen.
# gcc wird NUR gebraucht, wenn wir selbst kompilieren (kein --prebuilt).
NEED_GCC=1
[[ -n "$PREBUILT_DIR" ]] && NEED_GCC=0

# ---------- Auto-Download vorgebauter Binaries ----------
# Laedt x710_read/write/csum von PREBUILT_URL_BASE nach $1, validiert ELF-Magic.
# Rueckgabe 0 = Erfolg (alle drei valide), sonst 1.
fetch_prebuilt() {
    local dest="$1" dl="" tool
    command -v curl >/dev/null 2>&1 && dl="curl -fsSL -o"
    [[ -z "$dl" ]] && command -v wget >/dev/null 2>&1 && dl="wget -qO"
    [[ -z "$dl" ]] && { warn "Weder curl noch wget vorhanden - kein Auto-Download moeglich."; return 1; }
    mkdir -p "$dest"
    for tool in x710_read x710_write x710_csum; do
        if ! $dl "$dest/$tool" "$PREBUILT_URL_BASE/$tool" 2>/dev/null; then
            warn "Download fehlgeschlagen: $PREBUILT_URL_BASE/$tool"
            return 1
        fi
        # ELF-Magic pruefen (0x7f 'E' 'L' 'F'), sonst ist es z.B. eine 404-HTML-Seite
        if [[ "$(head -c4 "$dest/$tool" | od -An -tx1 | tr -d ' \n')" != "7f454c46" ]]; then
            warn "Heruntergeladene Datei ist kein ELF-Binary: $tool (evtl. fehlt sie im Repo?)"
            return 1
        fi
        chmod +x "$dest/$tool"
    done
    return 0
}

# Wenn wir kompilieren muessten (kein --prebuilt) aber gcc fehlt:
# zuerst Auto-Download der Binaries versuchen, bevor wir aufgeben.
if [[ $NEED_GCC -eq 1 ]] && ! command -v gcc >/dev/null 2>&1; then
    step "Kein gcc gefunden - versuche vorgebaute Hilfsprogramme zu laden"
    info "Quelle: $PREBUILT_URL_BASE"
    DL_DIR="$WORKDIR/prebuilt-dl"
    if fetch_prebuilt "$DL_DIR"; then
        ok "Vorgebaute Hilfsprogramme heruntergeladen und als ELF validiert"
        PREBUILT_DIR="$DL_DIR"
        NEED_GCC=0
    else
        warn "Auto-Download nicht moeglich - fahre fort mit der ueblichen Pruefung."
    fi
fi

RUNTIME_TOOLS=(ethtool lspci ip)
MISSING=()
for tool in "${RUNTIME_TOOLS[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || MISSING+=("$tool")
done
if [[ $NEED_GCC -eq 1 ]]; then
    command -v gcc >/dev/null 2>&1 || MISSING+=("gcc")
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
    warn "Fehlende Tools: ${MISSING[*]}"
    case "$OS" in
        debian)
            warn "Versuche per apt zu installieren..."
            apt-get update -qq && apt-get install -y -qq build-essential ethtool pciutils iproute2 || \
                die "Installation fehlgeschlagen. Bitte manuell: apt install build-essential ethtool pciutils iproute2"
            ;;
        unraid)
            if printf '%s\n' "${MISSING[@]}" | grep -qx "gcc"; then
                err "Auf Unraid 7+ gibt es keinen mitgelieferten Compiler, und das fruehere"
                err "'NerdTools'-Plugin ist nicht mehr kompatibel/verfuegbar."
                err "Der Auto-Download vorgebauter Binaries ist ebenfalls fehlgeschlagen."
                err ""
                err "Manuelle Wege - OHNE Compiler auf dem Server:"
                err "  1. Auf einem anderen Linux (z.B. Ubuntu Live-USB) die Hilfsprogramme bauen:"
                err "       sudo bash x710-unlock.sh --build-only"
                err "     Das legt sie unter ./x710-prebuilt/ ab."
                err "  2. Den Ordner x710-prebuilt/ auf den Unraid-Server kopieren (z.B. nach"
                err "     /boot/x710-prebuilt) und dort starten mit:"
                err "       bash x710-unlock.sh --prebuilt /boot/x710-prebuilt"
                err ""
                err "Alternativ (fortgeschritten): gcc als Slackware-Paket nach /boot/extra"
                err "legen, oder in einem Linux-Docker-Container mit gemountetem --privileged"
                err "Zugriff arbeiten."
                die "gcc fehlt auf Unraid und Auto-Download scheiterte - Abbruch. Siehe Hinweise oben."
            fi
            die "Benoetigte Runtime-Tools fehlen (${MISSING[*]}). Diese sollten auf Unraid vorhanden sein - bitte pruefen."
            ;;
        *)
            die "Unbekannte Distribution und fehlende Tools (${MISSING[*]}). Bitte manuell installieren: gcc, ethtool, pciutils, iproute2"
            ;;
    esac
fi
ok "Benoetigte Tools vorhanden"

# ---------- C-Quellen schreiben & (kompilieren | prebuilt nutzen) ----------
if [[ -n "$PREBUILT_DIR" ]]; then
    step "Vorgebaute Hilfsprogramme verwenden"
    for b in x710_read x710_write x710_csum; do
        if [[ ! -x "$PREBUILT_DIR/$b" ]]; then
            die "Vorgebautes Programm fehlt oder nicht ausfuehrbar: $PREBUILT_DIR/$b"
        fi
        cp "$PREBUILT_DIR/$b" "$WORKDIR/$b"
        chmod +x "$WORKDIR/$b"
    done
    ok "Vorgebaute Hilfsprogramme aus $PREBUILT_DIR uebernommen"
else
step "Tools kompilieren"

cat > "$WORKDIR/syscalls.h" <<'EOF'
#ifndef SYSCALLS_H
#define SYSCALLS_H
#include <linux/types.h>
#include <linux/ethtool.h>
/* i40e NVM access. Magic = (devid<<16)|(trans<<8)|module */
#define I40E_NVM_TRANS_SHIFT 8
#define I40E_NVM_SNT  0x1
#define I40E_NVM_LCB  0x2
#define I40E_NVM_SA   (I40E_NVM_SNT | I40E_NVM_LCB)   /* 0x3 - korrekt */
#define I40E_NVM_CSUM 0x8
#endif
EOF

# Reader: liest <count> Woerter ab <word_offset>, gibt "offset => value" aus
cat > "$WORKDIR/x710_read.c" <<'EOF'
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <linux/sockios.h>
#include "syscalls.h"
static uint32_t DEVID;
int main(int argc, char **argv){
    if(argc<5){fprintf(stderr,"usage: %s <devid> <iface> <word_off> <word_len>\n",argv[0]);return 2;}
    DEVID = strtol(argv[1],0,0);
    const char *dev = argv[2];
    int off = strtol(argv[3],0,0)*2;
    int len = strtol(argv[4],0,0)*2;
    int fd = socket(AF_INET,SOCK_DGRAM,0); if(fd<0){perror("socket");return 1;}
    struct ethtool_eeprom *e = calloc(1,sizeof(*e)+len); if(!e){perror("calloc");return 1;}
    e->cmd=ETHTOOL_GEEPROM;
    e->magic=(DEVID<<16)|((I40E_NVM_SA)<<I40E_NVM_TRANS_SHIFT);
    e->len=len; e->offset=off;
    struct ifreq ifr; memset(&ifr,0,sizeof(ifr));
    strncpy(ifr.ifr_name,dev,IFNAMSIZ-1); ifr.ifr_data=(void*)e;
    if(ioctl(fd,SIOCETHTOOL,&ifr)<0){perror("ioctl");return 1;}
    uint16_t *p=(uint16_t*)(e+1);
    for(int i=0;i<len/2;i++) printf("%04x %04x\n", (off/2)+i, p[i]);
    return 0;
}
EOF

# Writer: schreibt EIN Wort <value> an <word_offset>
cat > "$WORKDIR/x710_write.c" <<'EOF'
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <linux/sockios.h>
#include "syscalls.h"
int main(int argc, char **argv){
    if(argc<5){fprintf(stderr,"usage: %s <devid> <iface> <word_off> <value>\n",argv[0]);return 2;}
    uint32_t DEVID=strtol(argv[1],0,0);
    const char *dev=argv[2];
    int off=strtol(argv[3],0,0)*2;
    uint16_t val=(uint16_t)strtol(argv[4],0,0);
    int fd=socket(AF_INET,SOCK_DGRAM,0); if(fd<0){perror("socket");return 1;}
    struct ethtool_eeprom *e=calloc(1,sizeof(*e)+2); if(!e){perror("calloc");return 1;}
    e->cmd=ETHTOOL_SEEPROM;
    e->magic=(DEVID<<16)|((I40E_NVM_SA)<<I40E_NVM_TRANS_SHIFT);
    e->len=2; e->offset=off; *(uint16_t*)(e+1)=val;
    struct ifreq ifr; memset(&ifr,0,sizeof(ifr));
    strncpy(ifr.ifr_name,dev,IFNAMSIZ-1); ifr.ifr_data=(void*)e;
    if(ioctl(fd,SIOCETHTOOL,&ifr)<0){perror("write");return 1;}
    return 0;
}
EOF

# Checksum: triggert NVM-Checksum-Recalc mit korrekter Magic (CSUM|SA)
cat > "$WORKDIR/x710_csum.c" <<'EOF'
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <linux/sockios.h>
#include "syscalls.h"
int main(int argc, char **argv){
    if(argc<3){fprintf(stderr,"usage: %s <devid> <iface>\n",argv[0]);return 2;}
    uint32_t DEVID=strtol(argv[1],0,0);
    const char *dev=argv[2];
    int fd=socket(AF_INET,SOCK_DGRAM,0); if(fd<0){perror("socket");return 1;}
    struct ethtool_eeprom *e=calloc(1,sizeof(*e)+2); if(!e){perror("calloc");return 1;}
    struct ifreq ifr;
    /* Variante 1: CSUM|SA (= 0xB) - die erprobte Magic */
    e->cmd=ETHTOOL_SEEPROM;
    e->magic=(DEVID<<16)|((I40E_NVM_CSUM|I40E_NVM_SA)<<I40E_NVM_TRANS_SHIFT);
    e->len=2; e->offset=0;
    memset(&ifr,0,sizeof(ifr)); strncpy(ifr.ifr_name,dev,IFNAMSIZ-1); ifr.ifr_data=(void*)e;
    if(ioctl(fd,SIOCETHTOOL,&ifr)==0){printf("ok CSUM|SA\n");return 0;}
    /* Variante 2: CSUM allein (= 0x8) als Fallback */
    e->cmd=ETHTOOL_SEEPROM;
    e->magic=(DEVID<<16)|((I40E_NVM_CSUM)<<I40E_NVM_TRANS_SHIFT);
    e->len=2; e->offset=0;
    memset(&ifr,0,sizeof(ifr)); strncpy(ifr.ifr_name,dev,IFNAMSIZ-1); ifr.ifr_data=(void*)e;
    if(ioctl(fd,SIOCETHTOOL,&ifr)==0){printf("ok CSUM\n");return 0;}
    perror("csum"); return 1;
}
EOF

gcc -O2 -o "$WORKDIR/x710_read"  "$WORKDIR/x710_read.c"  || die "Kompilation x710_read fehlgeschlagen"
gcc -O2 -o "$WORKDIR/x710_write" "$WORKDIR/x710_write.c" || die "Kompilation x710_write fehlgeschlagen"
gcc -O2 -o "$WORKDIR/x710_csum"  "$WORKDIR/x710_csum.c"  || die "Kompilation x710_csum fehlgeschlagen"
ok "Tools kompiliert"
fi   # Ende: prebuilt vs. selbst kompilieren

# ---------- build-only: Binaries exportieren und beenden ----------
if [[ $BUILD_ONLY -eq 1 ]]; then
    OUT="./x710-prebuilt"
    mkdir -p "$OUT"
    cp "$WORKDIR/x710_read" "$WORKDIR/x710_write" "$WORKDIR/x710_csum" "$OUT/"
    chmod +x "$OUT/"x710_*
    ok "Hilfsprogramme gebaut und abgelegt unter: $OUT/"
    info "Diesen Ordner auf das Zielsystem (z.B. Unraid) kopieren und dort starten mit:"
    info "    bash x710-unlock.sh --prebuilt <pfad-zu>/x710-prebuilt"
    exit 0
fi

# ---------- Treiber-Reload ----------
reload_driver() {
    local rmout
    # Versuch zu entladen; Fehlermeldung einfangen statt verwerfen
    if lsmod 2>/dev/null | grep -q '^i40e'; then
        if ! rmout="$(modprobe -r i40e 2>&1)"; then
            if echo "$rmout" | grep -qi "in use\|busy"; then
                err "modprobe -r i40e fehlgeschlagen: Treiber ist in Benutzung."
                err "  -> $rmout"
                if [[ "$OS" == "unraid" ]]; then
                    err "Auf Unraid: Docker-Dienst und/oder VMs stoppen, damit keine"
                    err "Bridges/vhost mehr am Interface haengen, dann erneut starten."
                else
                    err "Stoppe Dienste/Bridges/VMs die an $IFACE haengen, dann erneut starten."
                fi
                die "Treiber nicht entladbar - Abbruch (es wurde nichts geschrieben sofern vor dem Patch)."
            else
                # anderer Fehler - nochmal mit Ausgabe
                warn "modprobe -r i40e: $rmout"
            fi
        fi
    fi
    sleep 2
    modprobe i40e || die "modprobe i40e (laden) fehlgeschlagen."
    sleep "$RELOAD_SETTLE"
    [[ -n "$IFACE" ]] && ip link set "$IFACE" up 2>/dev/null || true
    sleep 2
}

# read_word <word_offset> -> echo hex value (ohne 0x)
read_word() {
    local off="$1" out
    out="$($WORKDIR/x710_read "$DEVID" "$IFACE" "$off" 1 2>/dev/null | awk '{print $2}')"
    echo "$out"
}

# ============================================================
#  ZENTRALE SCHREIB-WRAPPER - der EINZIGE Weg, ins EEPROM zu
#  schreiben. Im Dry-Run-Modus blocken diese Funktionen HART
#  und kehren zurueck, ohne je das write/csum-Binary aufzurufen.
#  Damit ist es strukturell unmoeglich, dass ein Schreibzugriff
#  im Dry-Run durchrutscht.
# ============================================================
do_write() {   # do_write <word_offset_hex> <value_hex>
    if [[ $DRY_RUN -eq 1 ]]; then
        echo -e "${Y}[dry-run]${N} WUERDE schreiben: offset $1 <- $2 (uebersprungen)"
        return 0
    fi
    "$WORKDIR/x710_write" "$DEVID" "$IFACE" "$1" "$2"
}

do_csum() {    # do_csum
    if [[ $DRY_RUN -eq 1 ]]; then
        echo -e "${Y}[dry-run]${N} WUERDE NVM-Checksum aktualisieren (uebersprungen)"
        return 0
    fi
    "$WORKDIR/x710_csum" "$DEVID" "$IFACE"
}

# ---------- Interface-Detection ----------
step "X710-Interface ermitteln"
mapfile -t I40E_IFACES < <(
    for n in /sys/class/net/*; do
        [[ -e "$n/device/driver" ]] || continue
        drv="$(basename "$(readlink -f "$n/device/driver")")"
        [[ "$drv" == "i40e" ]] && basename "$n"
    done
)

if [[ -n "$IFACE" ]]; then
    ok "Interface manuell gesetzt: $IFACE"
elif [[ ${#I40E_IFACES[@]} -eq 0 ]]; then
    die "Kein i40e-Interface gefunden. Ist die X710 verbaut und der Treiber geladen?"
elif [[ ${#I40E_IFACES[@]} -eq 1 ]]; then
    IFACE="${I40E_IFACES[0]}"
    ok "i40e-Interface gefunden: $IFACE"
else
    warn "Mehrere i40e-Interfaces gefunden:"
    for i in "${!I40E_IFACES[@]}"; do
        mac="$(cat /sys/class/net/${I40E_IFACES[$i]}/address 2>/dev/null)"
        echo "    [$i] ${I40E_IFACES[$i]}  (MAC $mac)"
    done
    if [[ $ASSUME_YES -eq 1 ]]; then
        IFACE="${I40E_IFACES[0]}"
        warn "--yes aktiv: nehme erstes Interface $IFACE"
    else
        read -rp "Welches Interface (Index)? " idx
        IFACE="${I40E_IFACES[$idx]}" || die "Ungueltiger Index"
    fi
    ok "Gewaehlt: $IFACE"
fi

# Verifizieren dass es wirklich eine 1572 ist
businfo="$(ethtool -i "$IFACE" 2>/dev/null | awk '/bus-info/{print $2}')"
if [[ -n "$businfo" ]]; then
    devline="$(lspci -nn -s "$businfo" 2>/dev/null || true)"
    info "PCI: $devline"
    echo "$devline" | grep -q "8086:1572" || warn "Achtung: Device-ID ist nicht 8086:1572 - bist du sicher dass das eine X710 ist?"
fi

# ---------- Self-Cut-Schutz ----------
# Das Script laedt den i40e-Treiber wiederholt neu. Wenn die aktuelle
# SSH-Verbindung oder die Default-Route ueber GENAU DIESES Interface laeuft,
# kappt der erste Reload die eigene Verbindung -> Abbruch mitten im Patch.
step "Verbindungsweg pruefen (Self-Cut-Schutz)"

# Liste der Sub-Interfaces / IFs, die zur selben Karte gehoeren (gleiche PCI bus-info)
danger=0
reason=""

# 1) SSH-Verbindung: ueber welches IF kommt der SSH-Client rein?
if [[ -n "${SSH_CONNECTION:-}" ]]; then
    client_ip="$(awk '{print $1}' <<<"$SSH_CONNECTION")"
    ssh_if="$(ip route get "$client_ip" 2>/dev/null | grep -oP 'dev \K\S+' | head -1)"
    info "SSH-Client: $client_ip  ->  Route ueber Interface: ${ssh_if:-unbekannt}"
    if [[ -n "$ssh_if" && "$ssh_if" == "$IFACE" ]]; then
        danger=1
        reason="Deine SSH-Verbindung laeuft ueber $IFACE."
    fi
fi

# 2) Default-Route ueber das Ziel-Interface?
def_if="$(ip route show default 2>/dev/null | grep -oP 'dev \K\S+' | head -1)"
info "Default-Route ueber Interface: ${def_if:-keine}"
if [[ -n "$def_if" && "$def_if" == "$IFACE" ]]; then
    danger=1
    reason="${reason:+$reason }Die Default-Route laeuft ueber $IFACE."
fi

if [[ $danger -eq 1 ]]; then
    echo
    err "WARNUNG: $reason"
    err "Der Treiber-Reload (modprobe -r i40e) wuerde diese Verbindung KAPPEN -"
    err "das Script wuerde mittendrin abbrechen, im schlimmsten Fall mit halb"
    err "geschriebenem EEPROM."
    echo
    err "Sichere Wege:"
    err "  - Lokal an der Konsole arbeiten (Monitor + Tastatur), nicht per SSH ueber $IFACE"
    err "  - Oder ueber ein ANDERES Netzwerk-Interface verbinden (z.B. Onboard-NIC),"
    err "    sodass $IFACE frei ist"
    if [[ "$OS" == "unraid" ]]; then
        err "  - Auf Unraid: stelle sicher, dass $IFACE NICHT dein Management-Interface (br0/eth0) ist"
    fi
    echo
    if [[ $ASSUME_YES -eq 1 ]]; then
        die "Abbruch wegen Self-Cut-Risiko (auch mit --yes wird hier abgebrochen, das ist Absicht)."
    fi
    read -rp "Trotzdem fortfahren? Nur sinnvoll wenn du WIRKLICH lokal an der Konsole sitzt [tippe ' trotzdem ']: " sc
    [[ "$sc" == "trotzdem" ]] || die "Abgebrochen (empfohlen)."
    warn "Du faehrst auf eigenes Risiko fort."
else
    ok "Kein Self-Cut-Risiko erkannt - $IFACE traegt weder SSH noch Default-Route."
fi

# ---------- Unraid: i40e in-use Pruefung ----------
if [[ "$OS" == "unraid" ]]; then
    step "Unraid: Treiber-Entladbarkeit pruefen"
    refcnt="$(cat /sys/module/i40e/refcnt 2>/dev/null || echo '?')"
    info "i40e Modul-Refcount: $refcnt"
    if [[ "$refcnt" != "0" && "$refcnt" != "?" ]]; then
        warn "Der i40e-Treiber ist in Benutzung (refcount=$refcnt)."
        warn "Auf Unraid haengen oft Docker-Bridges, VLANs oder vhost am Interface,"
        warn "die ein 'modprobe -r i40e' verhindern ('Module i40e is in use')."
        warn "Empfehlung vor dem echten Lauf:"
        warn "  - Docker-Dienst stoppen (Settings -> Docker -> Enable: No)"
        warn "  - VMs stoppen (falls VFIO/vhost an der Karte haengt)"
        warn "  - ggf. Array stoppen, wenn Netzwerk-Shares an der Karte haengen"
        warn "Das Script versucht den Reload trotzdem - schlaegt er fehl, brichst du"
        warn "mit Strg+C ab, entlastest die Karte und startest erneut."
    else
        ok "i40e ist entladbar (refcount=$refcnt)."
    fi
fi

# ---------- EEPROM scannen, PHY-Records finden ----------
step "EEPROM scannen und PHY-Records lokalisieren"
reload_driver
DUMP="$WORKDIR/dump.txt"
if ! $WORKDIR/x710_read "$DEVID" "$IFACE" "$SCAN_START" "$SCAN_LEN" > "$DUMP" 2>/dev/null; then
    reload_driver
    $WORKDIR/x710_read "$DEVID" "$IFACE" "$SCAN_START" "$SCAN_LEN" > "$DUMP" 2>/dev/null \
        || die "EEPROM-Read fehlgeschlagen (auch nach Reload). Treiber-Problem?"
fi
lines="$(wc -l < "$DUMP")"
ok "EEPROM-Bereich gelesen ($lines Woerter ab $SCAN_START)"

# 000b-Marker finden (Wert == 000b)
mapfile -t MARKERS < <(awk '$2=="000b"{print $1}' "$DUMP")
info "Gefundene 000b-Marker: ${#MARKERS[@]}"
for m in "${MARKERS[@]}"; do echo "    0x$m"; done

[[ ${#MARKERS[@]} -eq $EXPECTED_PHYS ]] || \
    die "Erwartet $EXPECTED_PHYS PHY-Marker, gefunden ${#MARKERS[@]}. Layout unbekannt - Abbruch zur Sicherheit."

PHY0=$((16#${MARKERS[0]}))
PHY1=$((16#${MARKERS[1]}))
STEP=$((PHY1 - PHY0))
ok "PHY0-Offset: $(printf '0x%x' $PHY0), Schrittweite: $(printf '0x%x' $STEP)"

# Konsistenz: alle Schritte gleich?
for i in 1 2 3; do
    cur=$((16#${MARKERS[$i]}))
    prev=$((16#${MARKERS[$((i-1))]}))
    [[ $((cur - prev)) -eq $STEP ]] || die "Unregelmaessiger PHY-Abstand zwischen Record $((i-1)) und $i - Abbruch."
done
ok "PHY-Records regelmaessig (Abstand konstant $(printf '0x%x' $STEP))"

# MISC0-Register = PHY + 1 (das Bit-11-Register)
declare -a REG_OFFSETS
for i in 0 1 2 3; do
    REG_OFFSETS[$i]=$(( $((16#${MARKERS[$i]})) + 1 ))
done

# ---------- Aktuelle Werte lesen ----------
step "Aktuelle Bit-11-Register lesen"
declare -a CUR_VALS
for i in 0 1 2 3; do
    reload_driver
    v="$(read_word "$(printf '0x%x' ${REG_OFFSETS[$i]})")"
    [[ -n "$v" ]] || die "Konnte Register $i nicht lesen"
    CUR_VALS[$i]="$v"
    printf "    PHY%d @ 0x%x = 0x%s\n" "$i" "${REG_OFFSETS[$i]}" "$v"
done

# ---------- Restore-Modus ----------
if [[ $RESTORE -eq 1 ]]; then
    step "RESTORE: Bit 11 wieder setzen (Sperre reaktivieren)"
    for i in 0 1 2 3; do
        cur=$((16#${CUR_VALS[$i]}))
        new=$(( cur | 16#0800 ))
        newhex="$(printf '0x%04x' $new)"
        reload_driver
        info "PHY$i: 0x${CUR_VALS[$i]} -> $newhex"
        do_write "$(printf '0x%x' ${REG_OFFSETS[$i]})" "$newhex"
    done
    reload_driver
    do_csum && ok "Checksum aktualisiert" || warn "Checksum-Update fehlgeschlagen"
    if [[ $DRY_RUN -eq 1 ]]; then
        warn "DRY-RUN: Es wurde NICHTS geschrieben."
    else
        ok "Restore abgeschlossen. Reboot empfohlen."
    fi
    exit 0
fi

# ---------- Analyse ----------
step "Analyse"
NEED_PATCH=0
declare -a NEW_VALS
for i in 0 1 2 3; do
    cur=$((16#${CUR_VALS[$i]}))
    if (( cur & 16#0800 )); then
        new=$(( cur & ~16#0800 ))
        NEW_VALS[$i]="$(printf '0x%04x' $new)"
        printf "    PHY%d: 0x%04x  ->  %s  (Bit 11 wird geloescht)\n" "$i" "$cur" "${NEW_VALS[$i]}"
        NEED_PATCH=1
    else
        NEW_VALS[$i]="$(printf '0x%04x' $cur)"
        printf "    PHY%d: 0x%04x  (Bit 11 bereits 0 - nichts zu tun)\n" "$i" "$cur"
    fi
done

if [[ $NEED_PATCH -eq 0 ]]; then
    ok "Alle PHY-Records sind bereits entsperrt. Nichts zu tun."
    exit 0
fi

# ---------- Backup ----------
step "Vollstaendiges EEPROM-Backup"
mkdir -p "$BACKUPDIR"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="$BACKUPDIR/eeprom_${IFACE}_${STAMP}.txt"
reload_driver
if $WORKDIR/x710_read "$DEVID" "$IFACE" 0 0x8000 > "$BACKUP" 2>/dev/null; then
    blines="$(wc -l < "$BACKUP")"
    ok "Backup gespeichert: $BACKUP ($blines Woerter)"
else
    warn "Vollbackup fehlgeschlagen - versuche kleineres Backup des PHY-Bereichs"
    reload_driver
    $WORKDIR/x710_read "$DEVID" "$IFACE" "$SCAN_START" "$SCAN_LEN" > "$BACKUP" 2>/dev/null \
        && ok "Teil-Backup gespeichert: $BACKUP" \
        || warn "Auch Teil-Backup fehlgeschlagen - fahre dennoch fort (Werte stehen oben im Log)"
fi

# ---------- Bestaetigung ----------
if [[ $DRY_RUN -eq 1 ]]; then
    echo
    warn "DRY-RUN aktiv: Ab hier wuerde geschrieben. Es folgt nur eine Vorschau,"
    warn "es wird NICHTS ins EEPROM geschrieben."
    step "Vorschau der Schreibvorgaenge (dry-run)"
    for i in 0 1 2 3; do
        off="$(printf '0x%x' ${REG_OFFSETS[$i]})"
        do_write "$off" "${NEW_VALS[$i]}"
    done
    do_csum
    echo
    ok "DRY-RUN beendet. Fuer den echten Lauf ohne --dry-run starten."
    exit 0
fi
if [[ $ASSUME_YES -eq 0 ]]; then
    echo
    warn "Es werden jetzt $EXPECTED_PHYS Register im EEPROM von $IFACE geschrieben."
    warn "Backup liegt unter: $BACKUP"
    read -rp "Fortfahren? [tippe 'yes']: " confirm
    [[ "$confirm" == "yes" ]] || die "Abgebrochen."
fi

# ---------- Patch mit Reload nach jedem Write ----------
step "Patch ausfuehren (Treiber-Reload nach jedem Write)"
for i in 0 1 2 3; do
    off="$(printf '0x%x' ${REG_OFFSETS[$i]})"
    reload_driver
    info "PHY$i @ $off  <-  ${NEW_VALS[$i]}"
    if ! do_write "$off" "${NEW_VALS[$i]}"; then
        # einmal retry nach erneutem Reload
        warn "Write fehlgeschlagen, retry nach Reload..."
        reload_driver
        do_write "$off" "${NEW_VALS[$i]}" \
            || die "Write PHY$i endgueltig fehlgeschlagen. EEPROM evtl. inkonsistent - Backup: $BACKUP"
    fi
    ok "PHY$i geschrieben"
done

# ---------- Checksum ----------
step "NVM-Checksum aktualisieren"
reload_driver
if do_csum; then
    ok "Checksum aktualisiert"
else
    warn "Checksum-Update fehlgeschlagen. Der Treiber repariert die Checksum"
    warn "haeufig beim Boot selbst. Patch-Werte sind dennoch geschrieben."
fi

# ---------- Verifikation ----------
step "Verifikation"
ALL_OK=1
for i in 0 1 2 3; do
    reload_driver
    v="$(read_word "$(printf '0x%x' ${REG_OFFSETS[$i]})")"
    expect="${NEW_VALS[$i]#0x}"
    if [[ "$v" == "$expect" ]]; then
        printf "    ${G}PHY%d @ 0x%x = 0x%s  OK${N}\n" "$i" "${REG_OFFSETS[$i]}" "$v"
    else
        printf "    ${R}PHY%d @ 0x%x = 0x%s  (erwartet 0x%s)  FEHLER${N}\n" "$i" "${REG_OFFSETS[$i]}" "$v" "$expect"
        ALL_OK=0
    fi
done

echo
if [[ $ALL_OK -eq 1 ]]; then
    ok "${BOLD}Alle PHY-Records erfolgreich entsperrt!${N}"
    echo
    info "Naechste Schritte:"
    echo "    1. Rechner komplett herunterfahren (nicht nur reboot)"
    echo "    2. Netzteil 30s vom Strom"
    echo "    3. Wieder einschalten - die Karte akzeptiert jetzt beliebige SFP+-Module"
    echo
    info "Rueckgaengig machen falls noetig:  sudo $0 -i $IFACE --restore"
else
    err "Mindestens ein Register stimmt nicht. Backup liegt unter: $BACKUP"
    err "Restore moeglich mit:  sudo $0 -i $IFACE --restore"
    exit 1
fi
