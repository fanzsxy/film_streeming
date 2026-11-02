# Distribusi installer Windows Film Streaming

Chrome dapat mengklasifikasikan unduhan sebagai **dangerous**, **suspicious**, atau **unverified** karena banyak faktor. Status build GitHub Actions **bukan** bukti keamanan, dan tanda tangan kode juga **tidak menjamin** lolos pemeriksaan Chrome Safe Browsing.

## Mengaktifkan penerbitan installer yang ditandatangani

1. Dapatkan **Windows Authenticode code-signing certificate** dari penerbit tepercaya yang cocok untuk distribusi aplikasi. **Keystore Android (.jks) tidak bisa digunakan.** Beberapa penyedia memakai perangkat keras/cloud signing dan tidak menyediakan ekspor PFX; konfigurasi workflow saat ini hanya mendukung sertifikat **PFX yang dapat diekspor**. Untuk penyedia cloud signing dibutuhkan integrasi terpisah.
2. Simpan PFX dan password **di luar repository publik**, jangan kirimkan ke chat.
3. Di GitHub → Settings → Secrets and variables → Actions, tambahkan:
   - `WINDOWS_CODESIGN_PFX_BASE64`: isi file .pfx yang di-encode Base64 satu baris (bukan password atau .jks).
   - `WINDOWS_CODESIGN_PASSWORD`: password file PFX.
4. Jalankan workflow **Build Film Streaming Windows Desktop** di branch `main`.
5. Workflow menandatangani `film_streaming.exe` dan `Film-Streaming-Setup.exe` dengan SHA-256 timestamp dan menguji keduanya memakai `signtool verify /pa`. Hanya setelah berhasil, artifact **Film-Streaming-Windows-Installer** diterbitkan. Tanpa dua secret, hanya ZIP portable pengujian yang disediakan.
6. Unduh artifact **Film-Streaming-Windows-Checksums** dan bandingkan nilai SHA256 file installer untuk mendeteksi kerusakan/perubahan setelah build. Hash saja tidak membuktikan perangkat lunak aman.

## Jika Chrome masih memblokir

**Jangan** menonaktifkan Safe Browsing atau memaksa melewati peringatan. Periksa detail klasifikasi dan pindai file di sistem yang aman, kemudian gunakan jalur pelaporan false-positive Google untuk pemilik/penerbit software jika hasil pemeriksaan lain mendukung. Google mungkin memerlukan pemeriksaan tambahan atau reputasi publikasi yang stabil.

Installer Windows ini **tidak** menjadi ditandatangani hanya dengan membuat secret Android `FILMSTREAM_KEYSTORE_BASE64`; itu fungsi yang berbeda.
