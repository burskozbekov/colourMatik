# Mükemmel Renk Eşleştirme Plugin'i — Teknik Plan (v2, maksimum doğruluk)

> **Tek amaç:** 2. videoyu, 1. videonun renklerine **ölçülebilir şekilde en doğru** biçimde getirmek.
> Her şey **lokal** (internetsiz). Donanım: Apple M3 Max. Kullanım: kişisel.
> Tüm teknik kararlar burada verilmiştir; kullanıcının bilmesi gereken tek şey sonuç.

---

## 0. En baştaki üç karar (ve nedenleri, sade dille)

1. **Dil: Python.**
   Renk doğruluğunu *dil* değil *matematik* belirler. Rust daha hızlı bir mutfaktır ama model
   sahne başına bir kez çalışır → hız zaten sorun değil. Python'da renk biliminin tüm hazır,
   test edilmiş araçları var (bu yüzden doğruluğu Python'da kazanırız). **Rust yalnızca** ileride
   "kurulumsuz tek dosya" dağıtmak istersek, o da sadece son/donmuş algoritma için — kişiselde gereksiz.

2. **Çekirdek: renk bilimi, saf AI değil.**
   Nöral stil transferi (PhotoWCT/AdaIN) *estetik* içindir, renk *kaydırabilir* → doğruluk için yanlış.
   Maksimum doğruluk = **doğru renk yönetimi + Optimal Transport matematiği + ölçülen renk hatası (ΔE)**.

3. **AI'nin doğru görevi: "neyi neye eşleyeceğimizi" bulmak.**
   Lokal bir yapay zeka modeli, iki karede **cildi, nötr grileri, gökyüzünü, aynı nesneleri** tanır.
   Böylece "cilt cilde, gri griye" eşlenir. Renk dönüşümünü ise **hassas klasik çözücü** yapar.
   Yani: **AI = akıllı eşleştirme; renk bilimi = doğru dönüşüm.** Bu melez, saf AI'den daha doğrudur.

---

## 1. Doğruluğun ölçüsü: ΔE (bu olmadan "maksimum" laftan ibarettir)

Renk farkını gözle değil **sayıyla** ölçeriz: **CIEDE2000 (ΔE00)** — insan gözüne göre iki renk
arasındaki algısal fark.

| ΔE00 | Anlamı |
|---|---|
| < 1 | Göz **fark edemez** (mükemmel) |
| 1–2 | Çok yakın (profesyonel hedef) |
| 2–3 | İyi |
| > 5 | Gözle belli fark |

**Plugin, eşleştirmeden önce ve sonra ΔE'yi hesaplayıp gösterir** (özellikle cilt ve nötr griler
üzerinde). "Maksimum doğruluk" = bu sayıyı ölçüp minimuma indirmek. Hedef: cilt/nötr ΔE00 < 2.
Bu ölçüm+optimizasyon döngüsü, ucuz araçların yapmadığı ve bu planı gerçekten "mükemmel" yapan şey.

---

## 2. Doğruluk nereye göre değişir? (footage rejimi — otomatik algılanır)

Plugin iki videoya bakıp en doğru yöntemi kendi seçer:

| Rejim | Durum | Yöntem | Ulaşılabilir doğruluk |
|---|---|---|---|
| **A** | Karede **renk kartı** var (ColorChecker vb.) | Kartı iki videoda da bul, yamaları referansa çöz | **Neredeyse kusursuz** (ΔE≈1) |
| **B** | **Aynı sahne/özne** (çok kameralı, A/B cam) | AI ile eşleşen bölgeleri bul → çiftlerden dönüşüm çöz | Çok yüksek |
| **C** | **Farklı sahneler**, sadece "renkler uysun" | Dağılım eşleştirme (Optimal Transport) + cilt/gri koruması | Yüksek, ama içeriğe bağlı |

> Senin durumun büyük ihtimalle **B veya C**. İki videoda aynı kişi/mekan varsa doğruluk B'ye
> (çok yüksek) çıkar; tamamen farklıysa C'de "renk paleti/atmosferi" eşleşir. Kartın varsa (A) söyle,
> aracı ona göre kalibre ederim — o zaman ΔE≈1 mümkün.

---

## 3. Çekirdek boru hattı (adım adım)

```
1) OKU + LİNEARİZE (renk yönetimi — doğruluğun temeli)
   • Kaynak gamma/log ve renk primerlerini çöz → sahne-lineer ışığa getir.
   • Ham 8-bit sRGB üzerinde istatistik yapmak = ucuz araçların hata yaptığı yer. Biz yapmıyoruz.

2) HİZALA — nötr griler (beyaz dengesi + pozlama)
   • AI, iki karedeki nötr/gri bölgeleri bulur → önce beyaz dengesi ve pozlamayı birebir oturt.
   • Bu tek adım algılanan doğruluğun yarısıdır; nötrler tutunca gerisi kolay.

3) EŞLE — 3B renk dağılımı (Optimal Transport)
   • Pitié'nin MKL (Monge–Kantorovich lineer) yöntemi: ortalama + tam kovaryansı kapalı-form
     ve YUMUŞAK eşler → artefakt/banding yok. Daha yüksek sadakat gerekirse tam 3B histogram
     OT (IDT + regrain).
   • Cilt ve nötrler AI maskeleriyle KORUNUR/ayrı hedeflenir → cilt tonu bozulmaz.

4) PİŞİR — 65³ 3D LUT
   • Dönüşümü yüksek çözünürlüklü (65³, 33³ değil) bir .cube LUT'a yaz → maksimum hassasiyet,
     bant yok. Her şey float hesaplanır.

5) ÖLÇ — ΔE raporu
   • Eşleşen bölgelerde/ciltte/nötrde ΔE00'ı hesapla, önce/sonra göster. Gerekirse 2–3'e iterasyon.

6) UYGULA — Premiere Lumetri
   • .cube, klibe Input LUT olarak girer → gerçek zamanlı, düzenlenebilir. Panel olmasa da çalışır.
```

**Zamansal tutarlılık:** sahne başına tek LUT → titreme imkânsız. (Işık kayan uzun planlarda
2–3 çapa karede LUT + anahtarlama; ileri seviye.)

---

## 4. Teknoloji yığını (hepsi lokal, M3 Max'te)

| Katman | Seçim | Görev |
|---|---|---|
| Dil/motor | **Python 3.12** (uv venv; sistemdeki 3.14 çok yeni) | Tüm mantık |
| Renk bilimi | **colour-science**, numpy, scipy | Lineerizasyon, Lab/Oklab, ΔE00 |
| Eşleştirme mat. | **POT** (Python Optimal Transport) + Pitié MKL | 3B dağılım eşleme |
| Kart algılama (A) | OpenCV **mcc** / colour-science ColorChecker | ΔE≈1 kalibrasyon |
| Lokal AI — segmentasyon | Cilt/yüz (BiSeNet face-parsing) + gökyüzü; M3'te MPS/CoreML | "Neyi neye eşle" |
| Lokal AI — eşlenik (B) | DINOv2 (küçük) dense feature | Aynı nesneyi iki karede eşle (opsiyonel) |
| Kare çıkarma | **ffmpeg** (kurulu) | Klipten temsili kare |
| Köprü | localhost HTTP (FastAPI) | Panel ↔ motor (UXP Node kısıtını aşar) |
| Panel | UXP (Premiere 2026) / CEP; ya da watch-folder | Tek-tık konfor (ertelenebilir) |
| Uygulama | Lumetri **Input LUT** | .cube → gerçek zamanlı |

Tüm modeller lokal, açık ağırlıklı ve **v1 için eğitimsiz** — indir, çalıştır. İnternet gerekmez.

---

## 5. Yol haritası

| Aşama | Çıktı | Süre |
|---|---|---|
| **M0** | venv + renk-yönetimli boru hattı; CLI: `video1 + video2 → match.cube` (MKL çekirdek) | ~1 gün |
| **M1** | **ΔE ölçümü + önce/sonra raporu** — doğruluğu görünür yap | ~1 gün |
| **M2** | Lokal AI segmentasyon → **cilt/nötr koruması** (doğrulukta en büyük sıçrama) | 2–3 gün |
| **M3** | Rejim A (renk kartı) + Rejim B (eşlenik) otomatik algılama | 2–3 gün |
| **M4** | ffmpeg entegrasyon + minimal panel (Referans/Eşleştir/Uygula/ΔE göster) | 2–3 gün |
| **M5** *(ops.)* | CoreML dışa aktarım, tam 3B OT, keyframe'li LUT | 2–4 gün |

**M0–M2 zaten "mükemmel"e çok yakın sonuç verir.** Gerisi konfor + uç durumlar.

---

## 6. Rust ne zaman? (kararın gerekçesi)

Rust yalnızca şu senaryoda mantıklı: aracı **başkalarına, Python kurmadan tek `.app`/binary**
olarak dağıtmak istersen — o zaman *donmuş* algoritmayı Rust + `ort` (ONNX Runtime, CoreML) ile
tek dosyaya derleriz. **Doğruluğa katkısı sıfırdır** (aynı matematik). Kişisel kullanımda
Python daha hızlı geliştirilir, aynı doğrulukta. Karar: **şimdilik Python, gerekirse sonra Rust portu.**

---

## 7. En dürüst özet
- Doğruluk = **renk yönetimi (lineer) + Optimal Transport + ΔE ölçümü**, dil ya da "AI parlaklığı" değil.
- AI'yi **eşleştirmeyi akıllandırmak** için kullanıyoruz (cilt/gri/aynı-nesne), rengi kaydırması için değil.
- **Ölçüyoruz** (ΔE00) → "mükemmel"i iddia değil, sayı olarak gösteriyoruz.
- İki videon aynı özneyi ya da bir renk kartını içeriyorsa doğruluk kusursuza yaklaşır — bana söyle, ona göre ayarlarım.

## 8. Sıradaki adım
M0 dersen: uv ile Python 3.12 venv + colour-science/POT/opencv kurup,
`video1 + video2 → match.cube` üreten (renk-yönetimli MKL çekirdekli) çalışan bir CLI yazarım;
sen Premiere'de LUT'u klibe atıp sonucu görürsün. İlk günden ölçülebilir doğruluk.
