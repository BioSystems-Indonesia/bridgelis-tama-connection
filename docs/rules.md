# Aturan Menulis Kode — bridgeLIS-Tama-Connection

Aturan ini berlaku untuk semua kode di repo ini: core Haxe, platform layer, facade per bahasa, test, dan script build. Tujuannya satu: **kode yang kecil, mudah dibaca manusia, dan sama polanya di setiap bahasa.**

Kalau sebuah aturan bertentangan dengan aturan wajib dari bahasa atau tool (misalnya compiler Haxe atau PSR-4 di PHP), **aturan bahasa yang menang**, dan pengecualiannya dicatat di dokumen ini.

---

## 1. Bahasa

| Bagian | Bahasa |
|---|---|
| Nama file, folder, class, function, variabel, konstanta, kode error | **Inggris** |
| Komentar dan doc di dalam kode | **Inggris** |
| Pesan error dan log dari library | **Inggris** |
| Dokumen proyek (`*.md`: desain, README, aturan) | Indonesia |

Gunakan kata Inggris yang umum dan utuh. Hindari singkatan yang tidak lazim dan campuran bahasa.

| ✅ Benar | ❌ Salah |
|---|---|
| `normalizeSex`, `dateOfBirth`, `orderId` | `normJK`, `tglLahir`, `oid`, `getHasil` |

Singkatan yang **boleh** dipakai: `id`, `url`, `http`, `json`, `api`, `pdf`, `loinc`, `lis`, `his`, `simrs`, `ms` (milidetik), `sec` (detik).

---

## 2. Penamaan file dan folder

**Aturan dasar: `kebab-case`**, yaitu huruf kecil semua dengan kata dipisah tanda `-`. Ada **dua pengecualian yang dipaksa oleh tool**.

| Jenis file | Aturan | Contoh | Alasan |
|---|---|---|---|
| Source Haxe `.hx` | **PascalCase**, sama dengan nama type utamanya | `OrderValidator.hx`, `HisApi.hx` | Wajib dari compiler Haxe: nama modul harus diawali huruf besar. |
| Folder package Haxe | **huruf kecil, satu kata** (`snake_case` bila memang harus dua kata) | `core/`, `platform/php/` | Wajib dari Haxe: nama package diawali huruf kecil dan tidak boleh memakai `-`. |
| Class PHP di facade | **PascalCase**, sama dengan nama class | `Client.php`, `LisException.php` | Wajib dari autoload PSR-4. |
| File JS/TS facade dan script | `kebab-case` | `index.mjs`, `index.d.ts`, `build.mjs`, `mock-server.mjs` | Aturan dasar |
| Skenario dan fixture test (`.json`) | `kebab-case` + nomor urut 2 digit | `01-create-order-success.json`, `get-result-final.json` | Aturan dasar, dan urutannya jelas |
| Dokumen `.md` | `kebab-case` | `systemdesign-high.md`, `rules.md` | Aturan dasar |
| File standar di root | huruf besar sesuai konvensi umum | `README.md`, `CHANGELOG.md`, `LICENSE` | Konvensi umum yang dikenali semua orang |
| Config tool | sesuai nama yang diminta tool | `build-php.hxml`, `composer.json`, `package.json` | — |

**Aturan nama:**
- Nama file menjelaskan **isinya**, bukan jenisnya: `Sanitizer.hx`, bukan `Utils.hx` atau `Helper.hx`.
- Satu file berisi satu type utama (class, interface, atau typedef besar). Typedef kecil yang hanya dipakai oleh type itu boleh ditaruh di file yang sama.

---

## 3. Penamaan di dalam kode

| Hal | Aturan | Contoh |
|---|---|---|
| Class, interface, typedef, enum | PascalCase. Interface platform diawali `I`. | `CircuitBreaker`, `IHttp`, `LisError` |
| Function dan method | camelCase, **diawali kata kerja** | `createOrder`, `normalizeDateOfBirth`, `isValidLoinc` |
| Function yang mengembalikan Bool | diawali `is` / `has` / `can` / `should` | `isFinal`, `hasExpired`, `isTransient` |
| Variabel dan parameter | camelCase, kata benda yang jelas | `orderId`, `retryDelayMs`, `catalogAgeSec` |
| Konstanta | UPPER_SNAKE_CASE | `BREAKER_FAILURE_LIMIT`, `RETRY_DELAY_MS` |
| Kode error | UPPER_SNAKE_CASE, didaftarkan di LLD §5 | `LIS_UNAVAILABLE`, `UNKNOWN_TEST_CODE` |
| Environment variable | UPPER_SNAKE_CASE dengan prefix `LIS_` | `LIS_BASE_URL` |
| Key config dan nama method publik | camelCase | `baseUrl`, `unknownTestPolicy` |
| **Field data** (order, hasil, event, receipt) | **snake_case, sama persis dengan API HIS V2** | `order_id`, `date_of_birth`, `test_code` |
| Key storage | huruf kecil dengan pemisah `:` | `sent:<order_id>`, `cat:test-types` |

- **Satuan ditulis di nama variabel:** `timeoutMs`, `ttlSec`. Jangan hanya `timeout`.
- **Tidak ada nama satu huruf** selain `i`/`j` di loop pendek.
- **Hindari nama yang samar:** `data`, `info`, `tmp`, `obj`, `doStuff`, `process`. Pengecualian: `data` boleh dipakai bila memang merujuk ke field `data` di envelope API.

---

## 4. Dokumentasi di dalam kode (docs ringan)

**Wajib:**
1. **Setiap file/modul** punya doc 1–2 kalimat di bagian atas: apa tanggung jawabnya.
2. **Setiap function/method publik** punya doc comment yang berisi:
   - apa yang dilakukan (1 kalimat);
   - nilai balik atau callback-nya;
   - error (`LisError.code`) yang mungkin muncul;
   - perilaku LIS yang mendasarinya, bila ada, dengan merujuk kode F/D di dokumen desain.
3. **Function private** diberi doc **bila tidak jelas dari namanya**, misalnya karena menangani perilaku aneh dari server.
4. **Konstanta "angka ajaib"** diberi satu baris alasan.

**Isi doc menjelaskan "kenapa", bukan mengulang kode.**

```haxe
/**
 * Sends a new order or replaces an existing one in the LIS (server upsert by `order_id`).
 * Identical resubmissions are skipped because the LIS resets result approval on every edit (HLD F1).
 *
 * @param orderJson  order in HIS V2 shape (snake_case fields)
 * @param cb         outcome: receipt `{status: SENT|UNCHANGED, ...}` or LisError
 *                   VALIDATION_FAILED | UNKNOWN_TEST_CODE | LIS_REJECTED | LIS_UNAVAILABLE | ...
 */
public function createOrder(orderJson:String, cb:String->Void):Void
```

```haxe
// LIS silently maps any sex other than "M"/"F" to Unknown (HLD F3), so reject it here.
```

❌ **Jangan:** `// increment i`, `// call the API`, atau komentar yang sudah tidak sesuai dengan kodenya. Komentar yang salah lebih berbahaya daripada tidak ada komentar. Kalau kodenya diubah, komentarnya ikut diubah.

---

## 5. Struktur dan ukuran

- **Satu function, satu tugas.** Target ≤ 40 baris. Kalau lebih panjang, pecah menjadi beberapa function bernama.
- **Early return:** tangani kasus gagal di awal, lalu jalur sukses di akhir. Maksimal 3 level indentasi blok.
- **Tidak ada angka ajaib:** angka yang punya arti dijadikan konstanta bernama (`BREAKER_COOLDOWN_MS = 30000`).
- **Tidak ada kode mati**, kode yang di-comment-out, atau `TODO` tanpa nomor issue.
- **Format:** indentasi 2 spasi, panjang baris ≤ 100 karakter, dan selalu pakai kurung kurawal walau isinya satu baris.

---

## 6. Batas arsitektur (wajib)

| Lapisan | Boleh | Tidak boleh |
|---|---|---|
| **Core** (`src/core`) | logika, validasi, orkestrasi | I/O langsung (HTTP, file, env, jam), `#if php` / `#if js`, `Sys`, `untyped` |
| **Platform** (`src/platform/<target>`) | I/O lewat API runtime target | logika bisnis |
| **Facade** (`facade/<bahasa>`) | konversi tipe native ↔ JSON, Promise, exception | logika bisnis, validasi, aturan retry |

- **Semua I/O lewat interface di `Platform.hx`** (`IHttp`, `IStorage`, `IEnv`, `IClock`, `IHash`, `ILogger`). Dengan begitu core bisa dites dengan versi palsu (`FakeClock`, `MemoryStorage`).
- **Data di batas core ↔ facade selalu berupa string JSON + callback** (LLD §2). Exception tidak boleh menembus batas ini.
- **`IHttp` tidak pernah melempar exception.** Error jaringan dikembalikan sebagai data.
- **Hindari `Dynamic`.** Gunakan `typedef`. `Dynamic` hanya boleh dipakai tepat saat parse atau stringify JSON di batas core ↔ facade.
- **Jaga versi minimum runtime** (LLD §1.1: PHP 7.4, Node 18). Facade dan platform tidak boleh memakai fitur bahasa atau API di atas versi itu, misalnya fitur PHP 8 (union type, `match`, enum, `readonly`, named argument) atau API yang baru ada setelah Node 18. CI menguji versi minimum, jadi pelanggaran akan langsung gagal.

---

## 7. Cakupan fitur (anti over-engineering)

- **Fitur yang tidak ada di `systemdesign-low.md` tidak dibuat.** Fitur baru harus masuk dokumen desain dulu, lalu ditulis kodenya.
- Sebelum menambah kode, jawab: **masalah nyata apa yang diselesaikan?** Kalau jawabannya "mungkin nanti berguna", jangan ditambahkan.
- Daftar yang **sengaja tidak dibuat** ada di HLD §3. Jangan dihidupkan lagi tanpa keputusan baru.
- **Dependensi baru dilarang** tanpa persetujuan. Saat ini yang dipakai hanya Haxe std, `utest`, dan `hxnodejs`. Facade tidak memakai dependensi runtime apa pun.
- **Opsi config baru** hanya ditambahkan bila ada kebutuhan nyata dari RS, dan selalu dengan default yang aman.

---

## 8. Error

- Hanya gunakan kode error yang terdaftar di LLD §5. Kode baru wajib ditambahkan ke tabel itu di perubahan yang sama.
- **Pesan error ditujukan untuk manusia** dan menyebut apa yang salah serta cara memperbaikinya, misalnya `"LIS_BASE_URL is not set. Set it in the environment."`
- **`retryable` harus jujur:** `true` hanya untuk kondisi yang bisa sembuh dengan menunggu.
- **Error tidak boleh ditelan diam-diam.** Kalau sebuah error sengaja diabaikan, tulis alasannya di komentar dan catat di log.

---

## 9. Keamanan data pasien

- **Data pasien tidak boleh disimpan di storage.** Yang boleh hanya hash, id order, dan status.
- **Semua log lewat `Log`**, yang melakukan masking PHI. Jangan memanggil `trace`, `echo`, `console.log`, atau `error_log` langsung.
- **Tidak pernah di-log:** nilai hasil lab, `apiKey`, webhook secret, dan body request/response lengkap.
- **Perbandingan secret** wajib constant-time.

---

## 10. Test

- **Setiap function publik di core** punya unit test (`utest`) yang dijalankan di **target PHP dan JS**.
- **Setiap perilaku HTTP** (status, retry, breaker, webhook) punya skenario contract test JSON di `tests/contract/scenarios`, dipakai bersama oleh semua bahasa.
- **Setiap bug fix** disertai test yang gagal sebelum perbaikan.
- **Nama test** menjelaskan perilakunya, misalnya `testSexLMapsToM`, `testIdenticalOrderIsNotResent`.
- **Fixture** hanya berisi data palsu atau data yang sudah dibersihkan dari identitas pasien.
- Test tidak boleh bergantung pada jam asli atau jaringan asli. Gunakan `FakeClock` dan mock LIS.

---

## 11. Perubahan, versi, dan dokumen

- **Pesan commit** memakai [Conventional Commits](https://www.conventionalcommits.org/), dalam bahasa Inggris: `feat: add deleteOrder`, `fix: normalize DD/MM/YYYY dates`.
- **SemVer**, dengan satu nomor versi untuk semua bahasa. Perubahan API publik yang tidak kompatibel menaikkan versi mayor. Setiap rilis dicatat di `CHANGELOG.md`.
- **Perilaku berubah → dokumen ikut berubah** di perubahan yang sama, yaitu `systemdesign-low.md` dan/atau `README.md`.
- **Nama method publik harus jujur terhadap efeknya di LIS.** Contohnya `deleteOrder`, bukan `cancelOrder`, karena server menghapus permanen.

---

## Checklist sebelum merge

- [ ] Nama file mengikuti §2, dan nama di dalam kode mengikuti §3, semua dalam bahasa Inggris.
- [ ] Setiap modul dan function publik punya doc ringan (§4).
- [ ] Tidak ada I/O di core dan tidak ada logika di facade (§6).
- [ ] Fitur ini memang tercantum di dokumen desain (§7).
- [ ] Tidak ada data pasien atau secret di log maupun storage (§9).
- [ ] Unit test dan contract test lulus di target PHP dan JS (§10).
- [ ] Dokumen desain dan README sudah diperbarui bila perilaku berubah (§11).
