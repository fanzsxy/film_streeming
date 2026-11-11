# SignPath Foundation — persiapan tanda tangan Windows Film Streaming

**Status: BELUM DITANDATANGANI.** File ini hanya menjelaskan konfigurasi alur resmi. Menambahkan workflow tidak otomatis memberi sertifikat, mengaktifkan langganan, atau membuat Windows mempercayai installer.

## Sebelum mendaftar (wajib dievaluasi pemilik proyek)

1. Tentukan apakah seluruh kode dan komponen aplikasi memang layak dirilis sebagai **open source**. Saat persiapan ini, repo belum memiliki `LICENSE`. **Jangan menambahkan lisensi secara otomatis**: pemilik harus memilih lisensi OSI yang sesuai dan memverifikasi hak distribusi semua komponen. SignPath Foundation dapat menolak aplikasi pribadi / kode yang tidak memenuhi syarat OSS.
2. Periksa kepatuhan distribusi konten dan dependensi, termasuk cara aplikasi menggunakan sumber film pihak ketiga; repository yang publik bukan bukti bahwa seluruh kontennya bebas lisensi atau diizinkan untuk didistribusikan.
3. Dokumentasikan fungsi aplikasi secara akurat, kebijakan privasi dan layanan eksternal yang diakses (misalnya TMDB / situs streaming). Jangan mengklaim aplikasi tidak mengirim data jika memang menghubungi API atau situs.
4. Buat dan tautkan **Code signing policy** yang benar-benar menggambarkan peran author, reviewer, approver dan prosedur review; aktifkan MFA pada GitHub/SignPath, serta pastikan rilis Windows dalam format yang akan ditandatangani sudah tersedia sebagaimana syarat Foundation.
5. Ajukan proyek secara pribadi di https://signpath.org/apply.html lalu tunggu keputusan. SignPath Foundation **tidak menjamin semua proyek diterima**, dan setiap penandatanganan memerlukan persetujuan.
6. Setelah disetujui, di SignPath tambahkan GitHub.com sebagai trusted build system dan hubungkan **SignPath GitHub App** ke repo `fanzsxy/film_streeming`. Buat SignPath project + policy sesuai keputusan penyedia.

Syarat: https://signpath.org/terms.html

Dokumentasi resmi konektor: https://docs.signpath.io/trusted-build-systems/github

## Konfigurasi GitHub setelah disetujui

Pada GitHub **Settings → Secrets and variables → Actions**, buat:

| Jenis | Nama | Isi |
|---|---|---|
| **Secret** | `SIGNPATH_API_TOKEN` | Token SignPath yang berhak membuat signing request; **jangan tempel di chat atau commit** |
| Variable | `SIGNPATH_ORGANIZATION_ID` | ID organisasi di SignPath |
| Variable | `SIGNPATH_PROJECT_SLUG` | Slug proyek SignPath |
| Variable | `SIGNPATH_SIGNING_POLICY_SLUG` | Slug signing policy untuk rilis resmi |
| Variable | `SIGNPATH_EXE_ARTIFACT_CONFIGURATION_SLUG` | Config yang menandatangani `film_streaming.exe` |
| Variable | `SIGNPATH_INSTALLER_ARTIFACT_CONFIGURATION_SLUG` | Config yang menandatangani `Film-Streaming-Setup.exe` |

**Kedua artifact configuration harus dibuat sendiri di SignPath.** Artifacts diunggah oleh `actions/upload-artifact@v4` sebagai ZIP: definisikan `zip-file` root dalam artifact configuration, tandatangani hanya EXE yang dipilih, terapkan batasan metadata produk dan versi. Tidak boleh memakai satu konfigurasi dengan pola yang ikut menandatangani binary milik pihak ketiga. Periksa nama/struktur ZIP dan aturan SignPath di dashboard sebelum menjalankan build.

SignPath melakukan penandatanganan di infrastrukturnya sendiri. Jangan membuat / mengunggah PFX atau private key Foundation ke GitHub. Secrets PFX di workflow lama adalah jalur sertifikat **milik sendiri**, bukan bagian dari SignPath.

## Menjalankan build dan Release

1. Pastikan kode ini sudah ada di branch `main` dan proyek telah disetujui dan dikonfigurasi di SignPath. Buka **Actions → Build Film Streaming Windows Desktop**; gunakan **Run workflow** pada `main`, set `sign_with_signpath = true`. Nilai `personal_installer` tidak menyebabkan installer unsigned dibagikan saat SignPath aktif.
2. Workflow membangun `film_streaming.exe` di Windows runner GitHub, mengunggah unsigned EXE untuk verifikasi asal, mengirim permintaan tanda tangan SignPath, menunggu persetujuan dan memverifikasi Authenticode; baru kemudian membuat portable ZIP dan installer Inno Setup. Installer diunggah untuk permintaan tanda tangan kedua, diverifikasi, lalu diunggah sebagai **`Film-Streaming-Windows-Installer`** (signed) dan **`Film-Streaming-Windows-Portable`**.
3. Jika persetujuan, token, metadata atau status signature tidak valid, job **gagal**, tidak mengubah file unsigned menjadi artifact signed. Bila proses persetujuan tidak selesai dalam timeout, jalankan ulang build setelah ada approval. Kegagalan tersebut tidak boleh disiasati dengan melewati pemeriksaan tanda tangan.
4. Untuk GitHub Releases, jalankan APK Android dari **commit main yang sama** dengan Windows. Di **Publish Film Streaming Release** gunakan ID kedua run sukses. Gunakan **versi/tag baru**, karena `v1.0.0` sudah dipakai; sinkronkan metadata versi aplikasi/installer sebelum rilis berikutnya.
5. Verifikasi tanda tangan installer setelah unduh melalui **Properties → Digital Signatures** atau PowerShell `Get-AuthenticodeSignature .\Film-Streaming-Setup.exe`. Bandingkan checksum SHA-256. Tanda tangan yang valid tidak menjamin Windows/Chrome tak pernah menampilkan peringatan reputasi.

**Jangan gunakan `PERSONAL-UNSIGNED-Installer` sebagai rilis publik.** Jalur build lama tanpa SignPath tetap tersedia untuk pengujian pribadi, sementara jalur sertifikat PFX lama tetap didukung.

## Status dan batasan

- Belum ada sertifikat atau akun SignPath terverifikasi yang ditautkan oleh persiapan ini.
- Belum ada perubahan pada hak cipta/lisensi kode sumber dan belum ada privacy policy yang dinyatakan sudah sesuai.
- Tidak ada binary Windows yang ditandatangani sampai alur resmi SignPath sukses pada GitHub-hosted build.
- Status persyaratan lisensi, review kebijakan, dan keputusan SignPath sepenuhnya bergantung pada pemilik proyek serta penyedia sertifikat.
