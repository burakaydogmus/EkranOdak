# EkranOdak

İmleç bir ekrandan diğerine geçtiğinde, o ekrandaki pencereyi tıklamadan aktif eder.
Aynı ekranda gezinirken hiçbir şey yapmaz.

## Kurulum

```bash
./build.sh --install
```

Uygulama `~/Applications/EkranOdak.app` konumuna kopyalanır ve başlatılır. Menü çubuğunda iki ekran simgesi görünür.
İlk açılışta **Sistem Ayarları → Gizlilik ve Güvenlik → Erişilebilirlik** bölümünden EkranOdak'a izin ver.

## Menü

- **Etkin**: aracı açar veya kapatır.
- **Gecikme**: odak değişmeden önce imlecin yeni ekranda ne kadar kalması gerektiği (varsayılan 100 ms).
- **Girişte başlat**: Mac açılınca otomatik başlatır.
- **Günlük tut**: `~/Library/Logs/EkranOdak.log` dosyasına kayıt yazar.

## Davranış

- Hedef, imlecin altındaki en üstteki penceredir. İmlecin altında pencere yoksa o ekrandaki en üstteki pencere seçilir.
- Fare tuşu basılıyken (sürükleme sırasında) ya da bir menü açıkken bekler.

## Not

Kod yeniden derlenince imza değişir ve macOS eski izni tanımaz. Bu durumda Erişilebilirlik listesinden
EkranOdak'ı **−** ile kaldır, sonra uygulamayı yeniden aç ve izni tekrar ver.

## Teşhis

```bash
~/Applications/EkranOdak.app/Contents/MacOS/EkranOdak --probe
```
