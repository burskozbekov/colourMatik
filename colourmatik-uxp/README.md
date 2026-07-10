# colourMatik — Premiere Pro UXP Paneli

Premiere Pro'nun **içinde** açılan panel. Klipleri seçersin, tek tıkla eşleştirir, önce/sonra
önizlemeyi ve ΔE'yi gösterir, `.cube`'u kaydeder. Motor senin makinende çalışan lokal sunucudur
(`colourmatik-app`); panel ona `http://127.0.0.1:8765` üzerinden bağlanır.

## Gereksinimler
- **Premiere Pro 26 (2026)** — seçim/medya-yolu API'leri hazır.
- Motor bağımlılıkları kurulu olmalı (ana klasördeki `requirements.txt`).
- **UXP Developer Tool GEREKMEZ** — panel, senin soundMatik/videoMatik eklentilerinle
  aynı klasöre (Adobe'un `UXP/Plugins/External`'ı) kurulur.

## Yükleme (bir kere) — test edildi, çalışıyor ✅
1. **Kur:**
   ```
   cd /path/to/colourMatik && ./install-panel.sh
   ```
   (Kayıt dosyasını yedekler, paneli `com.colourmatik.panel_1.0.0` olarak kurar,
   Premiere UXP kaydına ekler. Diğer eklentilerine dokunmaz.)
2. **Premiere'i yeniden başlat** (UXP eklentileri sadece açılışta yüklenir).
3. **Motoru başlat** (panel açıkken açık kalmalı):
   ```
   ./colourmatik-app
   ```
4. Premiere: **Window ▸ UXP Plugins ▸ colourMatik**.

> Panelin HTML/JS'ini değiştirdiysen `./install-panel.sh`'i tekrar çalıştır ve
> Premiere'i yeniden başlat.

## Kullanım (arayüz İngilizce)
1. **REFERENCE** — beğendiğin renkteki klibi seç → **Use selected clip**.
2. **TARGET** — düzeltilecek klibi **timeline'da** seç → **Use selected clip** (efekt bu klibe eklenir).
3. **Different scene / Same scene** → **MATCH & APPLY**.
   - Panel eşleştirir ve **Lumetri Color efektini hedef klibe otomatik ekler**; önce/sonra önizleme çıkar.
4. **INTENSITY** slider'ıyla gücü ayarla (canlı önizleme; azalt/artır).
5. Effect Controls ▸ Lumetri ▸ Basic Correction ▸ **Input LUT** açılır menüsünden **colourMatik**'i seç
   (Browse'a gerek yok — LUT dropdown'a kurulur).

## Dürüst sınırlar (Premiere'in API'si yüzünden)
- Panel Lumetri'yi **otomatik ekler**, ama LUT'u API'yle **seçemez** (Input LUT menü-index'tir, yol değil;
  index sayılamaz). Bu yüzden LUT'u dropdown'dan **sen** seçersin — ama bu bir dosya-Browse değil, tek tık.
- **colourMatik** dropdown'a, motorun LUT'u yazmasından + **Premiere'in bir kez yeniden başlamasından**
  sonra düşer (Premiere LUT klasörlerini yalnızca açılışta tarar).
- Intensity'yi değiştirince, klipte görmek için Input LUT'u **yeniden seç** (Premiere LUT'ları önbelleğe alır).

## Güncelleme denetimi ("Güncellemeleri denetle" düğmesi)
Düğme şu adrese bakar: `https://catheadai.com/colourmatik/version.json`.
Oraya şu formatta bir dosya koyarsan gerçek güncelleme bildirimi çalışır:
```json
{ "version": "1.1.0", "url": "https://catheadai.com/colourmatik" }
```
Yerel sürümden (şu an `1.0.0`) yeniyse "Yeni sürüm var" gösterir; dosya yoksa nazikçe
"Denetlenemedi" der. Yerel sürüm `main.js` içindeki `LOCAL_VERSION` ile tanımlı.

## Sorun giderme
- **"Başarısız… motor açık mı"** → `./colourmatik-app` çalışmıyor. Başlat.
- Panel yüklenmiyor → geliştirici modu açık mı, Premiere yeniden başlatıldı mı, UDT 2.2+ mı?
- "Klip seçili değil" → bin'de ya da timeline'da tek bir video klibi seçili olmalı.
