# LieraOS NVIDIA-Treiber-Paketierung

Erzeugt aus offiziellen NVIDIA `.run`-Installern saubere `.deb`-Pakete,
die sich korrekt in Debian-basierte Systeme integrieren: DKMS-
Kernelmodul-Quellen, GLVND/Mesa-verträglicher Userspace,
Multiarch-(32-bit-)Kompatibilitätsbibliotheken und Secure-Boot-
Vorbereitung.

Entwickelt für [LieraOS](https://github.com/LieraOS) — eine
Wayland-first Gaming-Distribution — aber die Skripte brauchen nur
einen Debian-artigen Userspace (`dpkg-deb`, `dkms`) und laufen
eigenständig.

## Verifikationsstatus — bitte zuerst lesen

| Treiber-Branch | Modulpfad | Status |
|---|---|---|
| **580.x** (Pascal, GTX 10xx und älter) | proprietäres `kernel/` | **Auf echter Hardware verifiziert** — GTX 1060 6GB, selbstgebauter Kernel 7.3.x: DKMS-Build, Boot, Wayland-Session, GL funktionieren |
| **595.x** (Turing und neuer, RTX) | `kernel-open/` (GSP) | **Pakete bauen sauber, sind aber auf echter Hardware UNGETESTET** — dem Maintainer steht keine RTX-Karte zur Verfügung. Siehe „Mithilfe gesucht" weiter unten |

Der Test-Compile in `build_nvidia_all.sh` verifiziert nur, dass die
Kernel-Module gegen die Ziel-Kernel-Headers **kompilieren**. Er sagt
nichts über das Laufzeitverhalten aus — Modul laden, Display-Ausgabe,
Wayland, Suspend. Dieser Unterschied ist wichtig.

Wer Turing-/RTX-Hardware besitzt: Rückmeldungen, Testberichte und
Fixes sind ausdrücklich willkommen — siehe
[Mithilfe gesucht](#mithilfe-gesucht-rtxturing-tester).

## Erzeugte Pakete pro Version

| Paket | Inhalt |
|---|---|
| `liera-nvidia-<BR>-dkms` | Kernelmodul-Quellen + dkms.conf (5 Module: nvidia, modeset, drm, uvm, peermem), nouveau-Blacklist, GSP-Firmware, MOK-/Secure-Boot-Vorbereitung, DRM-Ordering-Unit |
| `liera-nvidia-<BR>-driver` | 64-bit Vendor-Bibliotheken, Vulkan/EGL/OpenCL-ICDs, GBM-Backend, VDPAU, Xorg-Treiber + -Module, Werkzeuge (nvidia-smi, nvidia-settings, …), systemd-Suspend/Resume-Units, udev-Devnode-Regel |
| `liera-nvidia-<BR>-32bit` | i386-Kompatibilitätsbibliotheken (Steam/Wine) |

Die Ausgabe landet in `nvidia-packages/<VERSION>/`.

## Verwendung

1. `.run`-Installer von <https://www.nvidia.com/drivers> laden und
   **neben die Skripte** legen — bewusst kein automatischer Download
   und niemals ins Repo committen (NVIDIA-Lizenz, ~400 MB pro Datei;
   `.gitignore` deckt sie ab).
2. Den Batch-Builder ausführen:

   ```bash
   bash build_nvidia_all.sh
   ```

   Er verarbeitet jede gefundene `NVIDIA-Linux-x86_64-*.run` in
   Versionsreihenfolge:

   1. **Test-Kompilierung** der Kernel-Module gegen das neueste
      `linux-headers-*liera*.deb` in `ISO_PACKAGES_DIR` (exakt das,
      was DKMS auf einem installierten Liera-System sieht).
      Schlägt der Build fehl, wird die Version übersprungen —
      Log: `nvidia-packages/test-build-<VERSION>.log`.
   2. `build_nvidia_dkms.sh` → das DKMS-Paket.
   3. `build_nvidia_userspace.sh` → Driver- + 32-bit-Pakete.
   4. Sync aller gebauten Versionen in den Live-Build-Baum
      (`includes.binary`), wo der Calamares-Job `lieragpu` sie bei
      der Installation abholt.

   Beide Subskripte lassen sich auch einzeln mit einer `.run`-Datei
   als Argument aufrufen.

## Umgebungsvariablen

| Variable | Zweck | Standard |
|---|---|---|
| `KERNEL_HEADERS_DEB` | expliziter Pfad zu einem `linux-headers-*.deb` für den Test-Build | neuestes `linux-headers-*liera*.deb` in `ISO_PACKAGES_DIR` |
| `ISO_PACKAGES_DIR` | Verzeichnis, das nach Header-Paketen durchsucht wird | `<skriptdir>/../../Liera/config/packages.chroot` |
| `KERNEL_BUILD_DIR` | Fallback: Kernel-Build-Baum mit `linux-*/` | `<skriptdir>/../kernel/liera-kernel-build` |
| `ISO_DRIVER_DIR` | Sync-Ziel in der Live-Build-Config; `"off"` deaktiviert den Sync | `<skriptdir>/../../Liera/config/includes.binary/liera-drivers/nvidia` |
| `SKIP_TEST_BUILD=1` | Compile-Check komplett überspringen | aus |
| `FORCE_BUILD=1` | trotz fehlgeschlagenem Compile-Check paketieren | aus |

**Hinweis zu den Defaults:** Die `../../Liera/...`-Pfade setzen
voraus, dass die Skripte neben dem LieraOS-Live-Build-Baum liegen
(z. B. in einem `tools/`-Verzeichnis eines Geschwister-Checkouts).
Werden sie nicht gefunden, warnt das Skript nur und fährt ohne
Test-Compile/Sync fort — nichts bricht, aber der Pre-Flight-Check
fehlt. Außerhalb des LieraOS-Layouts die Variablen auf eigene
Kernel-Headers bzw. das Ausgabeverzeichnis zeigen lassen.

## Design-Entscheidungen

- **Branch-Erkennung:** `< 590` → proprietäres `kernel/` (Pascal-
  Pfad), `>= 590` → `kernel-open/` (GSP-Pfad, Turing+). Automatischer
  Fallback auf das andere Verzeichnis bei Layout-Änderungen.
- **GLVND-Disziplin:** Die Pakete liefern *nur* Vendor-
  Implementierungen. NVIDIAs Dispatcher-Kopien (`libGL.so`,
  `libEGL.so`, …) werden übersprungen — sie würden auf Dateiebene
  mit Debians `libgl1`/`libegl1`/`libglvnd0` kollidieren und das
  System-GL zerstören. NVIDIA registriert sich stattdessen über die
  Loader-Metadaten.
- **Gegenseitiger Ausschluss:** Jedes Branch-Paket `Provides` +
  `Conflicts` auf die virtuellen Namen `liera-nvidia-dkms` /
  `liera-nvidia-driver` — zwei Generationen können nie parallel
  installiert werden, ohne Branch-Listen hartzukodieren. Zusätzlich
  konfliktieren die Pakete mit dem kompletten Debian-NVIDIA-Stack
  inklusive `nvidia-alternative`/Diversion-Mechanismus.
- **Kernel-Unabhängigkeit:** DKMS kompiliert die Module für jeden
  installierten Kernel mit passenden Headers neu — die Pakete selbst
  sind kernel-versionsagnostisch. Neue Kernel-Serien können den
  Compile trotzdem brechen (Upstream-API-Änderungen); genau dafür
  existiert der Test-Build-Schritt.

## Secure Boot

Das DKMS-Paket bereitet MOK-Signierung in seiner `postinst` vor
(Schlüssel unter `/var/lib/dkms/mok.key`, Enrollment via `mokutil`
in die UEFI-Queue, Einmal-Passwort `liera` am blauen Shim-Screen).
Vollständiger Secure-Boot-Betrieb erfordert zusätzlich signierten
Shim/Bootloader und signierten Kernel — siehe `TODO.md`.

## Mithilfe gesucht: RTX/Turing+-Tester

Die 595er-Pakete (`kernel-open`/GSP-Pfad) bauen korrekt, liefen aber
noch nie auf echter Hardware. Wer eine Turing-oder-neuere NVIDIA-
GPU hat, braucht nur eine kurze Checkliste:

```bash
sudo apt install ./liera-nvidia-595-dkms_*.deb ./liera-nvidia-595-driver_*.deb
dkms status            # Modul sollte 'installed' für deinen Kernel zeigen
# Reboot, dann:
nvidia-smi             # GPU sollte gelistet sein
lsmod | grep nvidia    # Module geladen
```

Plus: Kommt die Wayland-Session hoch, läuft Vulkan (`vulkaninfo`),
überlebt Suspend/Resume? Berichte, was geht und was bricht — ideal
mit GPU-Modell, Kernel-Version und `dkms status`-Ausgabe — sind
gerade der wertvollste Beitrag.

Zweitwertvollste: `kernel-open/` gegen verschiedene Kernel-Versionen
kompilieren (keine GPU nötig — siehe `KERNEL_HEADERS_DEB`/
`KERNEL_BUILD_DIR` oben).

## Lizenz

GPL-3.0-or-later — siehe `LICENSE`. Gilt für die Build-Skripte.
Die NVIDIA-Treiber-Binärdateien bleiben proprietär und unterliegen
NVIDIAs Lizenz; sie werden vom Nutzer heruntergeladen und nie über
dieses Repository weitergegeben.
