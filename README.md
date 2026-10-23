# FilmStream — Offline Player HTML Parser

## Pemasangan
Salin isi folder `backend/` ke folder `backend/` repo FilmStream (jangan hapus file lain). Commit/push; Vercel otomatis deploy jika GitHub terhubung. Root Directory Vercel tetap `backend`. Tidak perlu build APK.

Endpoint baru: `POST /inspect/player-html` (lihat `/docs`). Input contoh:

```json
{
  "page_url": "https://example.com/movie",
  "html": "<html><h1>Contoh</h1><iframe title=\"SERVER\" src=\"https://example.org/embed/abc\"></iframe></html>"
}
```

Keluaran mengklasifikasi `embed`, `file_candidate`, `manifest_candidate`, atau `unknown_candidate`. Semua `status=unverified`; `direct_video_verified=false`. Ini bukan sumber playback otomatis, tidak mengambil halaman dari Vercel, tidak melewati 403, dan tidak mengeksekusi JavaScript. Player yang dibuat dinamis dengan JavaScript mungkin tidak muncul dalam HTML statis.

Untuk pengujian halaman publik yang boleh Anda akses, gunakan HTML yang Anda simpan sendiri dan tempel sebagai input POST melalui `/docs`; jangan kirim cookie/token. Hasilnya bisa digunakan untuk menentukan apakah integrasi embed resmi atau URL media yang tersedia cocok untuk player. Endpoint ini untuk pengujian pribadi: jangan publikasikan HTML sensitif di server terbuka.

Uji lokal: `python tests/test_parser.py` (dari root paket, setelah memasang requirements).
