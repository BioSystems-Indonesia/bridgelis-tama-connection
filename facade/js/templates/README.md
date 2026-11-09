# Integrasi LIS Tama

Folder ini dibuat oleh `npx bridgelis-tama-connection init`. File `{{FILE}}` milik proyek Anda: ubah sesuai kebutuhan. Library tetap di `node_modules`, jadi update versi tetap mungkin (`npm update bridgelis-tama-connection`).

## Langkah

1. **Isi environment variable** (di `.env` atau server Anda):
   ```
   LIS_BASE_URL=http://192.168.1.10:8322
   LIS_API_KEY=<sama dengan SimrsApiKey di pengaturan LIS>
   LIS_WEBHOOK_SECRET=<sama dengan auth webhook di LIS>
   ```
2. **Sambungkan database.** Buka `{{FILE}}` dan ganti bagian bertanda ★ (`saveResult` dan `hasFinalResult`). Contoh bawaan hanya menyimpan di memori supaya template langsung jalan.
3. **Pasang route webhook** di framework Anda (potongan kode dicetak oleh perintah `init`, atau lihat README paket). Isi URL route itu di pengaturan webhook LIS.
4. **Kirim order** dengan `sendOrder(order)` saat dokter meminta pemeriksaan.
5. *(Opsional)* **Jadwalkan pemulihan.** Panggil `recoverMissedResults('2026-11-04')` dari cron atau tombol admin untuk mengambil hasil yang terlewat.

## Aturan penting

- **Simpan hasil dengan upsert** per `(order_id, test_code)`. Hasil yang sama bisa datang lebih dari sekali (tombol Resend di LIS, hasil direvisi lalu di-approve ulang, `recoverMissedResults`). `INSERT` biasa akan membuat data ganda.
- Webhook hanya dikirim LIS setelah hasil selesai dan di-approve. Bila `saveResult` melempar error, LIS menandai pengiriman `FAILED` dan operator lab bisa menekan Resend.
- `recoverMissedResults(since)` mencari berdasarkan **tanggal order dibuat**, bukan tanggal approve. Order lama yang direvisi baru-baru ini hanya ketemu bila `since` mencakup tanggal order itu dibuat. LIS tidak punya filter "berubah sejak"; revisi dipulihkan dengan mengambil ulang semua order dalam jendela itu (satu request per order), jadi pilih `since` sesempit mungkin.
- Bila beberapa server memakai satu LIS, beri `LisClient` storage bersama lewat `new LisClient({ storage })` (objek sinkron dengan `get`, `set`, `delete`, `setIfAbsent`). Tanpa itu, penjagaan "order sedang dikirim" hanya berlaku di satu server.

## Contoh order

```js
await sendOrder({
  patient: { medical_record_number: 'RM-001234', first_name: 'Budi', date_of_birth: '1990-01-31', sex: 'L' },
  lis_order: { order_id: 'ORD-001', tests: [{ code: 'HB' }] }
});
```

Folder ini: `{{DIR}}`
