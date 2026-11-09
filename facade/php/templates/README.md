# Integrasi LIS Tama

Folder ini dibuat oleh `vendor/bin/bridgelis-tama-connection init`. File `lis.php` dan `webhook.php` milik proyek Anda: ubah sesuai kebutuhan. Library tetap di `vendor/`, jadi update versi tetap mungkin (`composer update`).

## Langkah

1. **Isi environment variable** (di `.env`, konfigurasi web server, atau PHP-FPM):
   ```
   LIS_BASE_URL=http://192.168.1.10:8322
   LIS_API_KEY=<sama dengan SimrsApiKey di pengaturan LIS>
   LIS_WEBHOOK_SECRET=<sama dengan auth webhook di LIS>
   ```
2. **Sambungkan database.** Buka `lis.php` dan ganti bagian bertanda ★ (`lisSaveResult` dan `lisHasFinalResult`). Contoh bawaan hanya menyimpan ke file sementara supaya template langsung jalan.
3. **Pasang webhook.**
   - Framework: pasang route dengan potongan kode yang dicetak oleh perintah `init`.
   - PHP biasa: arahkan URL ke `webhook.php` (3 baris). Isi URL itu di pengaturan webhook LIS.
4. **Kirim order** dengan `lisSendOrder($order)` saat dokter meminta pemeriksaan.
5. *(Opsional)* **Jadwalkan pemulihan.** Panggil `lisRecoverMissedResults('2026-11-04')` dari cron atau halaman admin untuk mengambil hasil yang terlewat.

## Aturan penting

- **Letakkan `lis.php` di luar folder web publik** (di luar `public/` atau `htdocs/`). Hanya `webhook.php` yang boleh punya URL, dan isinya hanya memanggil `lis.php`.
- **Simpan hasil dengan upsert** per `(order_id, test_code)`. Hasil yang sama bisa datang lebih dari sekali (tombol Resend di LIS, hasil direvisi lalu di-approve ulang, `lisRecoverMissedResults`). `INSERT` biasa akan membuat data ganda.
- Webhook hanya dikirim LIS setelah hasil selesai dan di-approve. Bila `lisSaveResult` melempar exception, LIS menandai pengiriman `FAILED` dan operator lab bisa menekan Resend.
- `lisRecoverMissedResults($since)` mencari berdasarkan **tanggal order dibuat**, bukan tanggal approve. Order lama yang direvisi baru-baru ini hanya ketemu bila `$since` mencakup tanggal order itu dibuat. LIS tidak punya filter "berubah sejak"; revisi dipulihkan dengan mengambil ulang semua order dalam jendela itu (satu request per order), jadi pilih `$since` sesempit mungkin. Proses panjang bisa terkena `max_execution_time`: kecilkan `limit` dan panggil lagi.
- Bila beberapa server memakai satu LIS, beri `Client` storage bersama lewat `new Client(['storage' => $objek])` (implementasi `BridgeLisTamaConnection\Storage`, misalnya tabel database). Tanpa itu, penjagaan "order sedang dikirim" hanya berlaku di satu server.

## Contoh order

```php
lisSendOrder([
    'patient' => ['medical_record_number' => 'RM-001234', 'first_name' => 'Budi',
                  'date_of_birth' => '1990-01-31', 'sex' => 'L'],
    'lis_order' => ['order_id' => 'ORD-001', 'tests' => [['code' => 'HB']]],
]);
```
