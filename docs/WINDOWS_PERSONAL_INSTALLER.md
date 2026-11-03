# Installer pribadi Film Streaming untuk Windows

Workflow **Build Film Streaming Windows Desktop** sekarang menyediakan pilihan
`personal_installer` saat **Run workflow**. Pilihan ini default-nya **true**.

Jika sertifikat Windows Code Signing belum ada, workflow akan:
- tetap membuat aplikasi portable dan checksum;
- membuat `Film-Streaming-Setup.exe` melalui Inno Setup saat opsi
  `personal_installer` dicentang;
- mengunggah installer sebagai artifact
  **Film-Streaming-Windows-PERSONAL-UNSIGNED-Installer** (retensi 3 hari).

Installer pribadi memiliki shortcut dan entri Windows **Installed apps → Uninstall**.
Identitas aplikasi dan lokasi instalasi tidak diubah, sehingga dimaksudkan untuk
pembaruan instalasi Film Streaming sebelumnya. Tutup aplikasi dahulu.

**Perhatian keamanan:** installer pribadi **tidak ditandatangani**. Google Chrome
atau Windows mungkin tetap memblokir unduhannya, termasuk ZIP hasil build.
Jangan mematikan Chrome Safe Browsing, SmartScreen, atau Defender demi
memaksa pemasangan. Artifact di repository publik tidak bersifat rahasia:
kata *pribadi* menjelaskan tujuan penggunaan, bukan kontrol akses.

Jika sertifikat Authenticode tepercaya telah tersedia, jalur installer
bertanda tangan dan verifikasi tanda tangan tetap digunakan untuk rilis.
Tanda tangan pun tidak menjamin Chrome mengizinkan unduhan.

Gunakan artifact checksum untuk membandingkan SHA-256 file yang diterima.
Checksum membuktikan konsistensi file, bukan bahwa aplikasi aman.
