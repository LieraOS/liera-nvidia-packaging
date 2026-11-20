# TODO — NVIDIA-Paketierung & Treiber-Integration

## Offen

- [ ] **RTX/Turing+-Verifikation (höchste Priorität):** Die 595er-
      Pakete (`kernel-open`/GSP-Pfad) bauen sauber, liefen aber noch
      nie auf echter Hardware. Benötigt: Installation auf einer
      Turing-oder-neueren GPU, `dkms status`, `nvidia-smi`,
      Wayland-Session, Vulkan (`vulkaninfo`), Suspend/Resume.
      Berichte willkommen — siehe README „Mithilfe gesucht".
- [ ] Pascal-Abdeckung über die Maintainer-Maschine hinaus:
      Vulkan/VDPAU/OpenCL, Steam/32-bit-Pfad, Suspend/Resume,
      Hibernate.
- [ ] Calamares-End-to-End-Test der GPU-Auswahl (`lieragpu`-Job):
      explizit Pascal, explizit neuer, Auto mit/ohne NVIDIA,
      übersprungen.
- [ ] Secure-Boot-Projekt: signierter Shim + signierter Liera-Kernel
      (MODULE_SIG), Liera-Zertifikat einbetten; danach optional
      vorkompilierte signierte NVIDIA-Module statt DKMS
      (Ubuntu-Modell: null Interaktion).
- [ ] MOK-Enrollment-UX für Anfänger: Hinweis-Dialog beim ersten
      Login (Passwort, Ablauf des Shim-Screens).
- [ ] CI-Compile-Check: `kernel/` und `kernel-open/` automatisch
      gegen mehrere Kernel-Header-Versionen bauen (keine GPU nötig)
      — z. B. GitHub Actions, die den `.run` zur Laufzeit zieht.
- [ ] Issue-Template für Hardware-Reports (GPU-Modell, Branch,
      Kernel, `dkms status`, geht/geht nicht).
- [ ] Neue NVIDIA-Versionen: `.run` neben die Skripte legen +
      `bash build_nvidia_all.sh` — ISO-Sync läuft automatisch,
      wenn `ISO_DRIVER_DIR` gesetzt ist.

## Erledigt

- [x] Batch-Builder `build_nvidia_all.sh` (alle .run -> .deb je Version)
- [x] Branch-Erkennung im DKMS-Skript (< 590 kernel/, >= 590 kernel-open/)
- [x] Test-Kompilierung gegen linux-headers-*liera*.deb vor dem Packen
- [x] Gegenseitige Konflikte zwischen Branches (Provides/Conflicts-
      Trick, ohne hardkodierte Versionslisten)
- [x] Conflicts gegen komplette Debian-NVIDIA-Schicht inkl.
      nvidia-alternative/glx-diversions
- [x] `libnvidia-egl-wayland1` als harte Depends + ins Live-Image
- [x] MOK/Secure-Boot-Vorbereitung im postinst
- [x] GPU-Generations-Erkennung im lieragpu-Job (PCI-Device-ID
      Schwelle 0x1e02, Klasse 0x03xxx gefiltert)
- [x] 32-bit-Depends `libc6` statt `libc6-i386` (sauberes Multiarch)
- [x] **Auf echter Pascal-Hardware verifiziert:** GTX 1060 6GB,
      Kernel 7.3.1-liera-gaming-amd64, Treiber 580.196.07 —
      DKMS-Build, Boot, Wayland-Session, GL funktionieren (alle drei
      `liera-nvidia-580-*`-Pakete aus dieser Pipeline installiert)
- [x] Englische Skript-Ausgaben + zweisprachige Doku für die
      Veröffentlichung
