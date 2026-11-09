# bridgeLIS-Tama-Connection

Library untuk menghubungkan **SIMRS** ke **LIS Tama** lewat API HIS V2. Cukup install, isi environment variable, lalu panggil method. Logika integrasi (validasi data, pencegahan kiriman ganda, penanganan LIS yang sedang down, dan penerimaan hasil lewat webhook) sudah ada di dalam library.

> **Status:** versi 0.1.0, belum dirilis ke npm dan Packagist. Nama paket JavaScript: `bridgelis-tama-connection`. Paket Composer: `tama-connection/bridgelis-tama-connection`.
> Dokumen desain: [brainstorming.md](docs/brainstorming.md) · Aturan menulis kode: [rules.md](docs/rules.md)

---

## Persyaratan

| Bahasa | Versi minimum | Catatan |
|---|---|---|
| **PHP** | **7.4** (diuji sampai 8.4) | Ekstensi `json`. `curl` disarankan. `openssl` hanya bila LIS memakai https. PHP 5.x tidak didukung. |
| **Node.js** | **18** (diuji sampai 24) | Tanpa dependensi tambahan. JavaScript dan TypeScript, CommonJS dan ESM. Tipe TypeScript butuh TS ≥ 4.7. |
| Python / Java / C# | belum dijadwalkan | Rencana Java ada di [archive/plan-java.md](docs/archive/plan-java.md); Python dan C# belum direncanakan. |

Berjalan di Windows (termasuk XAMPP) dan Linux. Tidak butuh database, cron, atau service tambahan.

---

## Yang wajib dibaca sebelum integrasi

> ⚠️ **1. `deleteOrder()` menghapus order secara permanen.**
> Order dihapus dari LIS beserta sampel dan daftar pemeriksaannya, **apa pun statusnya**, bahkan bila hasil sudah keluar atau sudah di-approve. Penghapusan tidak bisa dibatalkan. Kalau hanya ingin membatalkan sebagian pemeriksaan, kirim ulang order dengan `createOrder()` berisi daftar tes yang baru.

> ⚠️ **2. Mengubah order yang sudah ada akan me-reset approval hasil.**
> `createOrder()` dengan `order_id` yang sudah ada akan **mengganti** order di LIS: tes diganti total dan data pasien ditimpa. Bila auto-approve di LIS nonaktif, **approval hasil kembali menjadi "belum di-approve"**. Library otomatis menolak kiriman yang identik (tidak dikirim ulang) dan memberi warning `ORDER_RESUBMITTED` bila isi order berubah.

> ⚠️ **3. Hasil lab datang lewat webhook, dan hanya setelah di-approve.**
> LIS mengirim notifikasi hanya ketika pemeriksaan berstatus selesai **dan** sudah di-approve, termasuk saat approve ulang setelah revisi. Library tidak melakukan polling dan tidak berjalan sendiri di belakang layar. Kalau SIMRS sedang mati atau gagal menyimpan, LIS mencatat status kirim **FAILED**, lalu operator lab menekan **"Resend"** di LIS. Bila Resend terlewat, panggil `reconcile()` (lihat "Memulihkan hasil yang terlewat").

> ⚠️ **4. Handler hasil harus idempoten (upsert).**
> Hasil yang sama bisa datang lebih dari sekali (Resend, approve ulang setelah revisi). Simpan dengan **upsert per `(order_id, test_code)`**, jangan insert baru. Dengan cara ini, revisi otomatis menimpa nilai lama.

---

## Konfigurasi (environment variable)

Library membaca konfigurasi dari environment variable dengan cara standar tiap bahasa (PHP: `getenv`/`$_ENV`/`$_SERVER`, Node: `process.env`). Library **tidak** membaca file `.env` sendiri. Gunakan mekanisme standar runtime atau framework yang dipakai (misalnya `.env` milik framework, `dotenv`, `SetEnv` di Apache, atau environment sistem). Nilai-nilainya diisi saat instalasi bersama tim LIS.

| Env | Wajib | Isi |
|---|---|---|
| `LIS_BASE_URL` | ✅ | Alamat server LIS, misalnya `http://192.168.1.10:8322` |
| `LIS_API_KEY` | disarankan | Sama dengan **SimrsApiKey** di pengaturan LIS |
| `LIS_WEBHOOK_SECRET` | disarankan | Sama dengan nilai auth di pengaturan webhook LIS |
| `LIS_WEBHOOK_SECRET_HEADER` | – | Nama header auth webhook (default `X-API-Key`, atau `Authorization` untuk bearer) |
| `LIS_STORAGE_DIR` | – | Folder cache library (default folder temp sistem). **Harus di luar folder web publik.** Isi per aplikasi: tanpa ini, dua aplikasi di satu mesin yang menuju LIS yang sama berbagi catatan dedup dan penanda "sedang dikirim". |
| `LIS_TIMEOUT_MS` / `LIS_CONNECT_TIMEOUT_MS` | – | Default 8000 / 3000 |
| `LIS_UNKNOWN_TEST_POLICY` | – | `reject` (default), `warn`, atau `off` |
| `LIS_LOG_LEVEL` | – | Default `info` |

Untuk mengecek apakah konfigurasi sudah terbaca, panggil `health()`. Fungsi ini melaporkan `baseUrl`, `apiKeySet`, `webhookSecretSet`, dan apakah LIS bisa dihubungi, tanpa menampilkan nilai rahasia.

## Pengaturan di sisi LIS

1. **Integrasi SIMRS** diaktifkan dengan mode **API**. Tanpa ini, semua request ditolak dengan `BRIDGING_DISABLED`.
2. **SimrsApiKey** diisi dengan nilai yang sama dengan `LIS_API_KEY`.
3. **Webhook notifikasi hasil:**
   - URL: endpoint webhook milik SIMRS (lihat contoh di bawah)
   - Method: `POST`
   - Auth: `api_key`, header `X-API-Key`, nilai = `LIS_WEBHOOK_SECRET`
   - Template payload (tanpa nama pasien): `{"order_no":"{{OrderNo}}","status":"{{Status}}"}`

---

## Mulai cepat: perintah `init`

Perintah `init` membuat folder integrasi sekali jalan, berisi satu file milik Anda (client, kirim order, simpan hasil, webhook, pemulihan) dan README langkah demi langkah. Library tetap di `node_modules` atau `vendor/`, tidak disalin, jadi update versi tetap mungkin.

```bash
# JavaScript / TypeScript
npx bridgelis-tama-connection init [--dir client/bridgelis-tama-connection] [--lang ts|js] [--framework express|fastify|koa|hono|next|nest]

# PHP
vendor/bin/bridgelis-tama-connection init [--dir client/bridgelis-tama-connection] [--framework laravel|ci4|slim|symfony]
```

- **Tidak pernah menimpa** file yang sudah ada. `--force` hanya bila diminta, dan file yang akan diganti ditampilkan dulu.
- `--framework` **mencetak** potongan route webhook; file route Anda tidak diubah.
- PHP menghasilkan `lis.php` (logika, taruh **di luar folder web publik**), `webhook.php` (3 baris, endpoint untuk PHP biasa), dan `README.md`. JavaScript menghasilkan `lis.cjs` atau `lis.ts` dan `README.md`.
- Bagian bertanda ★ di file hasil `init` adalah tempat menyambungkan database Anda. Contoh bawaan menyimpan hasil di memori (JS) atau file sementara (PHP) supaya template langsung jalan.
- `init` tidak dijalankan otomatis saat `npm install` / `composer install`.

---

## Cara pakai (gambaran API)

### PHP
```php
use BridgeLisTamaConnection\Client;
use BridgeLisTamaConnection\LisException;

$lis = new Client();   // konfigurasi dari env

try {
    $receipt = $lis->createOrder([
        'patient' => [
            'medical_record_number' => 'RM-001234',
            'first_name'            => 'Budi',
            'date_of_birth'         => '15/05/1990',   // dinormalkan menjadi 1990-05-15
            'sex'                   => 'L',            // dinormalkan menjadi M
        ],
        'lis_order' => [
            'order_id' => 'ORD-202609001',
            'tests'    => [['loinc_code' => '2345-7']],
        ],
    ]);
    // $receipt['status'] = SENT | UNCHANGED
} catch (LisException $e) {
    if ($e->isRetryable()) { /* "LIS sedang tidak tersedia, coba lagi" */ }
    else { /* tampilkan $e->getMessage(), perbaiki data */ }
}
```

Endpoint webhook (`lis-webhook.php`), yang URL-nya diisi di pengaturan webhook LIS:
```php
$lis = new BridgeLisTamaConnection\Client();
$lis->onResult(function (array $event) use ($db) {
    // upsert ke DB SIMRS per (order_id, test_code)
});
$lis->serveWebhook();   // baca request, proses, kirim balasan ke LIS
```

### Node.js (JavaScript dan TypeScript)
Satu paket untuk JavaScript dan TypeScript, ESM (`import`) maupun CommonJS (`require`). Tipe TypeScript sudah ikut di paket, jadi tidak perlu `@types` tambahan dan tidak ada pilihan "versi TS".
```ts
import { LisClient, LisError } from 'bridgelis-tama-connection';
const lis = new LisClient();   // konfigurasi dari process.env

lis.onResult(async (event) => { await db.upsertLabResult(event); });

app.post('/lis/webhook', async (req, res) => {
  const r = await lis.handleWebhook(req);
  res.status(r.status).set(r.headers).send(r.body);
});
```

---

## Dipakai di framework apa pun

Tidak ada pilihan framework saat install. Library hanya bicara dalam bentuk dasar PHP dan JavaScript, dan semua framework dibangun di atas keduanya. Bagian yang berbeda antar-framework hanya **endpoint webhook** (sekitar 5 baris). Sisanya (`createOrder`, `getResult`, dan seterusnya) dipanggil dengan cara yang sama di mana pun.

`handleWebhook()` menerima request dalam bentuk apa pun yang dimiliki aplikasi:

| Yang diberikan | Contoh framework |
|---|---|
| Tanpa argumen (PHP) | PHP native, CodeIgniter 3, aplikasi lama |
| Objek request framework | Laravel, Symfony, Slim/Laminas (PSR-7), CodeIgniter 4, Express, NestJS, Fastify, Koa, Next.js, Hono, Bun, Deno |
| Body mentah + header | Framework lain apa pun. Body boleh string, Buffer, atau objek yang sudah di-parse. Header boleh berupa string, array, `Headers`, atau `Map`. |

Balasannya selalu `{status, headers, body}`, yang tinggal dikirim dengan cara framework masing-masing.

<details><summary><b>PHP native / CodeIgniter 3</b></summary>

```php
$lis->onResult(function (array $event) { /* upsert */ });
$lis->serveWebhook();
```
</details>

<details><summary><b>Laravel</b></summary>

```php
// config/services.php — wajib bila memakai `php artisan config:cache`,
// karena setelah config di-cache, .env tidak terbaca lagi saat runtime.
'lis' => [
    'baseUrl'    => env('LIS_BASE_URL'),
    'apiKey'     => env('LIS_API_KEY'),
    'webhook'    => ['secret' => env('LIS_WEBHOOK_SECRET')],
    'storageDir' => storage_path('app/lis'),
],

// app/Providers/AppServiceProvider.php → register()
$this->app->singleton(\BridgeLisTamaConnection\Client::class, function () {
    return new \BridgeLisTamaConnection\Client(config('services.lis') + ['logger' => logger()]);
});

// routes/api.php (route api tidak memakai CSRF)
Route::post('/lis/webhook', function (Illuminate\Http\Request $request, BridgeLisTamaConnection\Client $lis) {
    $lis->onResult(fn (array $event) => LabResult::upsertFromLis($event));
    $r = $lis->handleWebhook($request);
    return response($r['body'], $r['status'], $r['headers']);
});
```
Bila route webhook ditaruh di `routes/web.php`, kecualikan dari CSRF.
</details>

<details><summary><b>Symfony / Slim / Laminas / CodeIgniter 4</b></summary>

```php
$r = $lis->handleWebhook($request);   // Request Symfony, PSR-7, atau $this->request di CI4
// Symfony:  return new Response($r['body'], $r['status'], $r['headers']);
// PSR-7:    $response->getBody()->write($r['body']);
//           return $response->withStatus($r['status'])->withHeader('Content-Type', 'application/json');
// CI4:      return $this->response->setStatusCode($r['status'])
//               ->setContentType('application/json')->setBody($r['body']);
```
</details>

<details><summary><b>Express / NestJS / Fastify / Node http</b></summary>

```ts
// Express (dengan atau tanpa body parser)
app.post('/lis/webhook', async (req, res) => {
  const r = await lis.handleWebhook(req);
  res.status(r.status).set(r.headers).send(r.body);
});

// NestJS
@Post('lis/webhook')
async webhook(@Req() req: Request, @Res() res: Response) {
  const r = await this.lis.handleWebhook(req);
  res.status(r.status).set(r.headers).send(r.body);
}

// Fastify
app.post('/lis/webhook', async (request, reply) => {
  const r = await lis.handleWebhook(request);
  reply.code(r.status).headers(r.headers).send(r.body);
});
```
</details>

<details><summary><b>Next.js (App Router) / Hono / Bun / Deno</b></summary>

```ts
// app/api/lis/webhook/route.ts
export const runtime = 'nodejs';   // edge runtime tidak didukung (lihat catatan di bawah)

export async function POST(request: Request) {
  const r = await lis.handleWebhook(request);
  return new Response(r.body, r);
}
```
</details>

**Catatan lingkungan**
- **Edge runtime** (Cloudflare Workers, Next.js `runtime = 'edge'`) belum didukung, karena library memakai `fs` dan `crypto` milik Node. Route Node biasa di framework yang sama tetap bisa.
- **Serverless** (Lambda, Vercel, Cloud Run) bisa dipakai, tapi folder storage di sana tidak permanen. Pencegahan kiriman ganda dan jeda saat LIS mati hanya berlaku per instance. Arahkan `LIS_STORAGE_DIR` ke volume permanen bila tersedia.
- **Apache + header `Authorization`:** bila auth webhook memakai bearer, Apache kadang tidak meneruskan header ini ke PHP. Tambahkan `CGIPassAuth On` (Apache ≥ 2.4.13) atau `SetEnvIf Authorization "(.*)" HTTP_AUTHORIZATION=$1`.
- **Config eksplisit selalu didukung:** `new Client([...])` / `new LisClient({...})` menimpa env. Gunakan cara ini bila framework menyimpan config di tempat lain (config cache, secret manager).

## Memulihkan hasil yang terlewat: `reconcile()`

Webhook tetap jalur utama. `reconcile()` adalah jalur cadangan **sesuai permintaan** bila webhook gagal dan operator lupa menekan Resend. Panggil dari cron atau tombol admin Anda; **library tidak menjadwalkan dan tidak berjalan sendiri.**

```ts
lis.onResult(async (event) => { await db.upsertLabResult(event); });

const report = await lis.reconcile({
  since: '2026-11-04',                          // wajib: awal jendela waktu
  skip: (orderId) => db.hasFinalResult(orderId), // opsional: lewati order yang sudah Anda punya
  limit: 200,                                   // opsional: maksimum hasil diambil per panggilan (default 100)
});
// { checked, delivered, pending, skipped, failed: [{ order_id, error }], truncated }
```

```php
$report = $lis->reconcile([
    'since' => '2026-11-04',
    'skip'  => function (string $orderId): bool { return $db->hasFinalResult($orderId); },
]);
```

Cara kerja: library meminta daftar order berstatus selesai yang dibuat sejak `since`, membuang order yang bukan dari SIMRS (tanpa `barcode_simrs`), mengambil hasil tiap order, lalu memanggil handler `onResult` yang **sama dengan webhook** untuk hasil yang sudah final.

Batas yang harus Anda ketahui:
- **Jendela waktu = waktu order dibuat, bukan waktu approve.** LIS tidak punya filter "berubah sejak". Order lama yang baru di-approve atau direvisi kemarin hanya ketemu bila `since` mencakup tanggal order itu dibuat.
- **Memulihkan revisi berarti mengambil ulang semua order di jendela** (satu request per order), karena daftar order tidak membawa hasil maupun waktu approve. Pakai `skip` untuk order yang sudah lengkap di database Anda, dan pilih `since` sesempit mungkin.
- **Handler harus upsert.** Hasil yang sama bisa datang dari webhook dan dari `reconcile()` (peringatan 4).
- Satu order yang gagal (handler melempar error, LIS menolak) **tidak menghentikan** yang lain; ia dicatat di `failed`. Proses berhenti rapi (`truncated: true`) bila LIS mati, kunci API salah, atau `limit` tercapai. Panggil lagi dengan `skip` untuk melanjutkan.
- Bila daftar order sendiri tidak bisa dibaca, `reconcile()` melempar error (`AUTH_FAILED`, `LIS_UNAVAILABLE`, dan seterusnya).
- `skip` yang melempar exception membuat order itu masuk ke `failed` (tidak diambil). PHP: proses panjang bisa kena `max_execution_time`; kecilkan `limit`.

---

## Beberapa server atau serverless: storage bisa disuntik

Penjagaan "order sedang dikirim" dan pencegahan kiriman ganda memakai storage. Bawaannya file di folder lokal, jadi hanya berlaku di satu server. Bila beberapa server memakai satu LIS, suntikkan storage bersama:

```ts
// JavaScript: objek SINKRON (bukan Promise) dengan empat method
new LisClient({ storage: { get(key), set(key, value, ttlSec), delete(key), setIfAbsent(key, value, ttlSec) } });
```
```php
// PHP: objek yang mengimplementasikan BridgeLisTamaConnection\Storage
new Client(['storage' => new MyDatabaseStorage()]);
```

`setIfAbsent` harus atomik (contoh SQL: `INSERT` pada kolom unik, gagal bila sudah ada) dan mengembalikan `true` hanya bila kunci baru tersimpan. Isi storage hanya hash dan penanda pendek, tidak ada data pasien. **Antarmuka ini eksperimental sampai 1.0.** Di Node, storage harus sinkron (bukan Promise).

Storage file bawaan memakai pembuatan file eksklusif, atomik di disk lokal tetapi **tidak andal di share jaringan (NFS, share Windows)**; untuk multi-server, suntikkan storage sendiri.

### Daftar method
| Method | Fungsi |
|---|---|
| `createOrder(order)` | Kirim atau ubah order (lihat peringatan 2) |
| `deleteOrder(orderId)` | **Hapus permanen** order (lihat peringatan 1) |
| `updateNotes(orderId, notes)` | Ubah catatan order |
| `getOrder(orderId)` / `listOrders(filter)` | Lihat order |
| `getResult(orderId)` | Ambil hasil. Mengembalikan `PENDING` bila belum siap |
| `getResultPdf(orderId)` | PDF hasil |
| `getTestTypes()` / `getPackages()` / `getPackage(code)` | Katalog tes dan paket di LIS |
| `getUsers()` | Daftar dokter dan analis |
| `reconcile(options)` | Pulihkan hasil yang terlewat, sesuai permintaan (lihat "Memulihkan hasil yang terlewat") |
| `onResult(handler)` + `handleWebhook(request)` | Terima hasil dari LIS (lihat "Dipakai di framework apa pun"). PHP juga punya `serveWebhook()` |
| `health()` | Cek konfigurasi dan koneksi |

---

## Hal lain yang perlu diketahui

**Data order**
- **Format data:** order dan hasil memakai nama field **snake_case**, sama persis dengan dokumentasi API HIS V2 LIS.
- **Jenis kelamin** otomatis dinormalkan: `L/LAKI-LAKI/PRIA/1` → `M`, dan `P/PEREMPUAN/WANITA/2` → `F`. Nilai lain ditolak, karena LIS akan diam-diam mengubahnya menjadi "Unknown".
- **Tanggal lahir** boleh `YYYY-MM-DD`, `DD/MM/YYYY`, `DD-MM-YYYY`, dan beberapa format lain. Format dengan hari di depan dianggap **hari/bulan/tahun**.
- **Kode tes dicek ke katalog LIS** sebelum order dikirim. Tanpa pengecekan ini, LIS akan diam-diam membuang kode yang tidak dikenal, sehingga ada pemeriksaan pasien yang hilang. Kode boleh berupa kode LIS, alias, atau LOINC. Kode LOINC juga dicek check digit-nya.
- **`order_id`** boleh sepanjang apa pun, tapi **tidak boleh mengandung `/`**.

**Isi hasil lab** (dari `getResult()` dan event `onResult`, diverifikasi dengan LIS asli)
- Hasil ada di `order.results[]`. Tiap baris punya `test_code`, `test_name`, `result` (nilai, berupa teks), `unit`, `reference_range`, `abnormal_flag`, `is_critical`, `status` (`Final`), `package_code`, dan `validated_at`.
- **`abnormal_flag` kosong berarti normal.** Nilai lain misalnya `H`, `HH`, `L`, `LL`.
- Nilai direvisi di LIS lalu di-approve ulang: webhook datang lagi dengan nilai baru. Simpan dengan upsert per `(order_id, test_code)`.

**Balasan webhook ke LIS**

| Balasan | Artinya | Yang terjadi di LIS |
|---|---|---|
| `200 {"ok":true}` | Hasil diterima dan handler `onResult` selesai | Status kirim sukses |
| `401` | Secret salah atau tidak ada | FAILED. Periksa `LIS_WEBHOOK_SECRET` |
| `400` | Body tanpa nomor order, atau JSON rusak | FAILED |
| `404` | Hasil belum siap atau belum di-approve (`result pending`). Normal bila LIS mengirim tes webhook dengan nomor order contoh | FAILED. Aman, kirim ulang setelah hasil di-approve |
| `502` | LIS tidak bisa dihubungi saat library mengambil hasil | FAILED. Tekan **Resend** setelah LIS pulih |
| `500` | Handler `onResult` Anda melempar error | FAILED. Perbaiki handler, lalu **Resend** |

**Error dan kegagalan**
- **`ORDER_IN_PROGRESS`** (`retryable: true`): `createOrder()` kedua untuk `order_id` yang sama datang saat yang pertama masih mengirim. Library menolaknya seketika, tanpa menunggu. Coba lagi beberapa detik kemudian; bila kiriman pertama sudah berhasil, hasilnya `UNCHANGED`. Kunci kedaluwarsa sendiri setelah 30 detik bila prosesnya mati.
- **Error** selalu dilempar beserta flag `retryable`. `true` berarti LIS sedang tidak tersedia, jadi boleh dicoba lagi nanti. `false` berarti data atau konfigurasi salah, jadi perlu diperbaiki dulu. Library tidak menyimpan dan tidak mengirim ulang di belakang layar.
- **Saat LIS mati**, setelah 5 kali gagal berturut-turut library berhenti mencoba selama 30 detik, dan method langsung gagal tanpa menunggu timeout. Tujuannya supaya halaman SIMRS tidak macet dan LIS tidak dibanjiri request.

**Operasional**
- **Tidak perlu cron, service, atau database tambahan.** Library hanya menyimpan cache kecil (hash order, penanda "sedang dikirim", status koneksi, katalog tes) di `LIS_STORAGE_DIR`. **Tidak ada data pasien dan tidak ada hasil lab yang disimpan oleh library.** Penyimpanan hasil sepenuhnya urusan Anda lewat `onResult` (upsert).
- **Log:** nama pasien dan NIK disamarkan, sedangkan nilai hasil lab, API key, dan secret tidak pernah ditulis ke log.

---

## Untuk kontributor

Pemakai akhir **tidak** butuh Haxe: paket rilis berisi hasil build. Kontributor dan CI membutuhkan:

```bash
# Haxe 4.3.7 (https://haxe.org/download/), lalu:
haxelib install utest
haxelib install hxnodejs
npm test        # unit (Haxe: JS + PHP) -> build -> sinkron facade -> contract -> init
```

- `targets/` **tidak di-commit**; dibuat oleh `npm run build` (juga di CI dan saat rilis).
- `haxe` dipanggil dari PATH. Bila `haxelib` tidak bisa dipakai di mesin Anda, arahkan `HAXE_LIBS_DIR` ke folder yang berisi `utest/` dan `hxnodejs/` (hasil checkout), dan `scripts/run-haxe.mjs` mengganti `-lib` dengan `-cp`.
- Aturan kode: [docs/rules.md](docs/rules.md). Perubahan perilaku wajib masuk dokumen desain di perubahan yang sama.
