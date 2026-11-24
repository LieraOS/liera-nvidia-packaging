# LieraOS NVIDIA-Treiber-Paketierung

Bauwerkzeuge für die proprietären NVIDIA-Treiberpakete, die Liera
ausliefert: Aus NVIDIAs offiziellen `.run`-Installern entstehen
saubere `.deb`-Pakete, die sich korrekt in Debian-basierte Systeme
integrieren — DKMS-Kernelmodul-Quellen, GLVND/Mesa-verträglicher
Userspace, Multiarch-(32-bit-)Kompatibilitätsbibliotheken und
Secure-Boot-Vorbereitung.

Die Skripte brauchen nur einen Debian-artigen Userspace
(`dpkg-deb`, `dkms`) und laufen auf jedem vergleichbaren System.
Die dokumentierten Defaults entsprechen dem Liera-Build-Layout
und lassen sich über Umgebungsvariablen umleiten.

> **Status: experimentell.** Diese Skripte und die daraus erzeugten
> Pakete sind in Entwicklung und müssen gegebenenfalls weiter
> ausgearbeitet werden. Getestet wird ausschließlich auf Liera, der
> Debian-basierten Distribution, mit dem eigenen Liera-Kernel —
> nicht auf anderen Debian-basierten Distributionen oder deren
> Kerneln. Verwendung auf eigene Gefahr.

## Zwei Kernelmodul-Pfade

Jeder `.run`-Installer enthält einen von zwei Modulquell-Bäumen —
die Skripte erkennen automatisch, welcher vorhanden ist, und
paketieren ihn:

| Modulpfad | Verwendet von | Status hier |
|---|---|---|
| `kernel/` (proprietär) | Treiber-Branches für Hardware vor GSP | **Auf echter Hardware verifiziert** — GTX 1060 6GB auf dem aktuellen Liera-Kernel: DKMS-Build, Boot, Wayland-Session, GL funktionieren |
| `kernel-open/` (GSP) | Treiber-Branches für Turing und neuer | **Pakete bauen sauber, sind aber auf echter Hardware UNGETESTET** — siehe [Mithilfe gesucht](#mithilfe-gesucht-turing-tester) |

Der Test-Compile in `build_nvidia_all.sh` verifiziert nur, dass
die Kernel-Module gegen die Ziel-Kernel-Headers **kompilieren**.
Er sagt nichts über das Laufzeitverhalten aus — Modul laden,
Display-Ausgabe, Wayland, Suspend. Dieser Unterschied ist wichtig.

## Erzeugte Pakete pro Version

Beliebig viele Treiberversionen nebeneinander:

| Paket | Inhalt |
|---|---|
| `liera-nvidia-<BR>-dkms` | Kernelmodul-Quellen + dkms.conf (5 Module: nvidia, modeset, drm, uvm, peermem), nouveau-Blacklist, GSP-Firmware wo vorhanden, MOK-/Secure-Boot-Vorbereitung, DRM-Ordering-Unit |
| `liera-nvidia-<BR>-driver` | 64-bit Vendor-Bibliotheken, Vulkan/EGL/OpenCL-ICDs, GBM-Backend, VDPAU, Xorg-Treiber + -Module, Werkzeuge (nvidia-smi, nvidia-settings, …), systemd-Suspend/Resume-Units, udev-Devnode-Regel |
| `liera-nvidia-<BR>-32bit` | i386-Kompatibilitätsbibliotheken (Steam/Wine) |

Die Ausgabe landet in `nvidia-packages/<VERSION>/`.

## Verwendung

1. `.run`-Installer von <https://www.nvidia.com/drivers> laden und
   **neben die Skripte** legen. Es gibt bewusst keinen
   automatischen Download — NVIDIAs Lizenz erlaubt keine
   Weitergabe (~400 MB pro Datei), also stellt sie der Nutzer
   selbst bereit.
2. Den Batch-Builder ausführen:

   ```bash
   bash build_nvidia_all.sh
   ```

   Er verarbeitet jede gefundene `NVIDIA-Linux-x86_64-*.run` in
   Versionsreihenfolge:

   1. **Test-Kompilierung** der Kernel-Module gegen ein
      Kernel-Headers-`.deb` — exakt die Headers, die DKMS auf dem
      Zielsystem sehen wird. Schlägt der Build fehl, wird die
      Version übersprungen — Log:
      `nvidia-packages/test-build-<VERSION>.log`.
   2. `build_nvidia_dkms.sh` → das DKMS-Paket.
   3. `build_nvidia_userspace.sh` → Driver- + 32-bit-Pakete.
   4. Optionaler Sync der Ergebnisse in ein ISO-/Treiber-
      Verzeichnis (`ISO_DRIVER_DIR`).

   Beide Subskripte lassen sich auch einzeln mit einer `.run`-
   Datei als Argument aufrufen.

## Umgebungsvariablen

| Variable | Zweck | Standard |
|---|---|---|
| `KERNEL_HEADERS_DEB` | expliziter Pfad zu einem `linux-headers-*.deb` für den Test-Build | neuestes `linux-headers-*liera*.deb` in `ISO_PACKAGES_DIR` |
| `ISO_PACKAGES_DIR` | Verzeichnis, das nach Header-Paketen durchsucht wird | ein `packages.chroot`-Verzeichnis relativ zum Checkout |
| `KERNEL_BUILD_DIR` | Fallback: Kernel-Build-Baum mit `linux-*/` | ein `liera-kernel-build`-Verzeichnis relativ zum Checkout |
| `ISO_DRIVER_DIR` | Sync-Ziel für die gebauten `.deb`-Dateien; `"off"` deaktiviert den Sync | ein Live-Build-`includes.binary`-Verzeichnis relativ zum Checkout |
| `SKIP_TEST_BUILD=1` | Compile-Check komplett überspringen | aus |
| `FORCE_BUILD=1` | trotz fehlgeschlagenem Compile-Check paketieren | aus |

Die Pfad-Defaults entsprechen dem Liera-Build-Checkout. Werden
keine passenden Kernel-Headers gefunden, warnt das Skript nur und
fährt ohne Test-Compile fort — nichts bricht, aber der
Pre-Flight-Check fehlt. Für vollständig eigenständigen Betrieb
die Variablen auf eigene Headers bzw. das Ausgabeverzeichnis
zeigen lassen oder `ISO_DRIVER_DIR=off` setzen.

## Design-Entscheidungen

- **Modulpfad-Erkennung:** Die Skripte paketieren den Quell-Baum,
  den die `.run` liefert — `kernel/` auf Branches mit den
  proprietären Modulquellen, `kernel-open/` dort, wo NVIDIA auf
  die offenen, GSP-Firmware-basierten Module umgestiegen ist —
  mit automatischem Fallback auf das jeweils andere Verzeichnis
  bei Layout-Änderungen.
- **GLVND-Disziplin:** Die Pakete liefern *nur* Vendor-
  Implementierungen. NVIDIAs Dispatcher-Kopien (`libGL.so`,
  `libEGL.so`, …) werden übersprungen — sie würden auf Dateiebene
  mit Debians `libgl1`/`libegl1`/`libglvnd0` kollidieren und das
  System-GL zerstören. NVIDIA registriert sich stattdessen über
  die Loader-Metadaten.
- **Gegenseitiger Ausschluss:** Jedes Branch-Paket `Provides` +
  `Conflicts` auf die virtuellen Namen `liera-nvidia-dkms` /
  `liera-nvidia-driver` — zwei Generationen können nie parallel
  installiert werden, ohne Branch-Listen hartzukodieren.
  Zusätzlich konfliktieren die Pakete mit dem kompletten
  Debian-NVIDIA-Stack inklusive `nvidia-alternative`/Diversion-
  Mechanismus.
- **Kernel-Unabhängigkeit:** DKMS kompiliert die Module für jeden
  installierten Kernel mit passenden Headers neu — die Pakete
  selbst sind kernel-versionsagnostisch. Neue Kernel-Serien
  können den Compile trotzdem brechen (Upstream-API-Änderungen);
  genau dafür existiert der Test-Build-Schritt.

## Secure Boot

Das DKMS-Paket bereitet MOK-Signierung in seiner `postinst` vor
(Schlüssel unter `/var/lib/dkms/mok.key`, Enrollment via `mokutil`
in die UEFI-Queue, Einmal-Passwort `liera` am blauen Shim-Screen).
Vollständiger Secure-Boot-Betrieb erfordert zusätzlich signierten
Shim/Bootloader und signierten Kernel — siehe `TODO.md`.

## Mithilfe gesucht: Turing+-Tester

Pakete für den `kernel-open`/GSP-Pfad bauen korrekt, liefen hier
aber noch nie auf echter Hardware. Wer eine Turing-oder-neuere
NVIDIA-GPU hat, braucht nur eine kurze Checkliste:

```bash
sudo apt install ./liera-nvidia-*-dkms_*.deb ./liera-nvidia-*-driver_*.deb
dkms status            # Modul sollte 'installed' für deinen Kernel zeigen
# Reboot, dann:
nvidia-smi             # GPU sollte gelistet sein
lsmod | grep nvidia    # Module geladen
```

Plus: Kommt die Wayland-Session hoch, läuft Vulkan (`vulkaninfo`),
überlebt Suspend/Resume? Berichte, was geht und was bricht —
ideal mit GPU-Modell, Kernel-Version und `dkms status`-Ausgabe —
sind gerade der wertvollste Beitrag.

Zweitwertvollste: `kernel-open/` gegen verschiedene Kernel-
Versionen kompilieren (keine GPU nötig — siehe
`KERNEL_HEADERS_DEB`/`KERNEL_BUILD_DIR` oben).

## Lizenz

GPL-3.0-or-later — siehe `LICENSE`. Gilt für die Build-Skripte.
Die NVIDIA-Treiber-Binärdateien bleiben proprietär und unterliegen
NVIDIAs Lizenz; sie werden vom Nutzer heruntergeladen und nie über
dieses Repository weitergegeben.
