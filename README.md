# راهنمای استفاده: Optimizer v2.1 و Port-Forward v2.1

دو اسکریپت، دو مسئولیت جدا:

| اسکریپت | کارش |
|---|---|
| `vpn_network_optimizer_v2.1.sh` | آپتیمایز سرور: BBR، بافرها، backlog، limits و **تمام تنظیمات conntrack** |
| `port-forward-v2.1.sh` | فقط فوروارد پورت با iptables + `ip_forward` + MSS clamp |

## قانون «یک کلید، یک مالک»

| تنظیم | مالک |
|---|---|
| `nf_conntrack_max`، timeoutها، hashsize، لود ماژول در بوت | **Optimizer** (هر دو role) |
| `net.ipv4.ip_forward` | **Port-Forward** |
| قوانین iptables، سرویس systemd، MSS clamp | **Port-Forward** |
| BBR، بافرها، backlog، rp_filter، limits | **Optimizer** |

نتیجه: هیچ کلید sysctl را دو اسکریپت همزمان نمی‌نویسند و تداخلی پیش نمی‌آید.
ترتیب اجرا: **اول Optimizer، بعد Port-Forward**. برعکسش هم امن است، فقط Port-Forward هشدار می‌دهد.

---

## نصب (دانلود از گیت‌هاب)

مخزن: <https://github.com/APX01/VPN-Optimizer>

اسکریپت‌ها را **اول دانلود کن، بعد اجرا کن** (نه `curl | bash`). دلیلش:
Port-Forward باید از روی یک فایل اجرا شود تا بتواند خودش را در `/usr/local/sbin` نصب کند، و دانلود جدا به تو فرصت می‌دهد قبل از اجرا فایل را ببینی.

```bash
cd /root

# فقط Optimizer (برای نود)
curl -fsSL -O https://raw.githubusercontent.com/APX01/VPN-Optimizer/refs/heads/main/vpn_network_optimizer_v2.1.sh

# Port-Forward (فقط برای سرور فوروارد)
curl -fsSL -O https://raw.githubusercontent.com/APX01/VPN-Optimizer/refs/heads/main/port-forward-v2.1.sh
```

اگر `curl` نصب نیست: `apt-get update && apt-get install -y curl`، یا به‌جای آن `wget`:

```bash
wget https://raw.githubusercontent.com/APX01/VPN-Optimizer/refs/heads/main/vpn_network_optimizer_v2.1.sh
```

اختیاری: قبل از اجرا فایل را ببین یا syntax را چک کن:

```bash
less vpn_network_optimizer_v2.1.sh
bash -n vpn_network_optimizer_v2.1.sh && echo OK
```

### نصب سریع: سرور نود جدید

```bash
cd /root
curl -fsSL -O https://raw.githubusercontent.com/APX01/VPN-Optimizer/refs/heads/main/vpn_network_optimizer_v2.1.sh
sudo bash vpn_network_optimizer_v2.1.sh
```

### نصب سریع: سرور فوروارد جدید

```bash
cd /root
curl -fsSL -O https://raw.githubusercontent.com/APX01/VPN-Optimizer/refs/heads/main/vpn_network_optimizer_v2.1.sh
curl -fsSL -O https://raw.githubusercontent.com/APX01/VPN-Optimizer/refs/heads/main/port-forward-v2.1.sh

sudo bash vpn_network_optimizer_v2.1.sh --role forwarder      # اول Optimizer
sudo sh port-forward-v2.1.sh add 203.0.113.10 443             # بعد اولین فوروارد
```

با اولین `add`، اسکریپت خودش را به‌صورت دستور `port-forward` نصب می‌کند و سرویس بوت را فعال می‌کند. از آن به بعد:

```bash
port-forward add 203.0.113.10 8443
port-forward list
port-forward status
```

### آپدیت به نسخه‌ی جدید گیت‌هاب

`-O` فایل قبلی را بازنویسی می‌کند، پس همان دستورهای دانلود را دوباره بزن و اجرا کن (بخش «آپدیت سرورهای فعلی» پایین‌تر). برای Port-Forward بعد از دانلود حتماً:

```bash
sudo sh port-forward-v2.1.sh install
```

### اجرای گروهی روی چند سرور (اختیاری)

اول روی یک سرور تست کن. بعد برای نودها:

```bash
for h in node1 node2 node3; do
  ssh root@$h 'cd /root && curl -fsSL -O https://raw.githubusercontent.com/APX01/VPN-Optimizer/refs/heads/main/vpn_network_optimizer_v2.1.sh && bash vpn_network_optimizer_v2.1.sh'
done
```

### ثابت نگه داشتن نسخه

لینک‌های بالا به شاخه‌ی `main` اشاره می‌کنند؛ هر تغییری که روی main بگذاری، سرورهای بعدی همان را می‌گیرند. برای نسخه‌ی ثابت، یک **tag** بساز (مثلاً `v2.1.0`) و به‌جای `refs/heads/main` از `refs/tags/v2.1.0` استفاده کن:

```
https://raw.githubusercontent.com/APX01/VPN-Optimizer/refs/tags/v2.1.0/vpn_network_optimizer_v2.1.sh
```

---

## چه چیزی در v2.1 عوض شد؟

1. **conntrack روی سرور خام اعمال می‌شد؟ نه. حالا می‌شود.**
   قبلاً اگر `nf_conntrack` هنوز لود نبود (قبل از نصب داکر/ufw)، تنظیمات skip می‌شد. حالا Optimizer ماژول را همان لحظه لود می‌کند، در `modules-load.d` می‌گذارد و فایل sysctl را بدون شرط می‌نویسد. مقدارها بعد از نصب داکر و بعد از ریبوت هم برقرار می‌مانند.
2. **تداخل دو اسکریپت روی conntrack حل شد.** Port-Forward دیگر conntrack را ست نمی‌کند، فقط چک و هشدار می‌دهد.
3. `nf_conntrack_max` حالا بر اساس رم انتخاب می‌شود (جدول پایین) و هیچ‌وقت کم نمی‌شود.
4. hashsize هم زنده اعمال می‌شود و هم با `modprobe.d` دائمی می‌شود.
5. فایل‌های بکاپ حالا اسم مسیر کامل دارند (قبلاً دو فایل هم‌نام روی هم می‌نشستند).
6. دستور جدید `install` در Port-Forward برای آپدیت سرورهای فعلی.

### مقدار `nf_conntrack_max` بر اساس رم

| رم | مقدار |
|---|---|
| کمتر از حدود ۳ گیگ | 262144 |
| حدود ۴ تا ۶ گیگ | 524288 |
| حدود ۸ تا ۱۲ گیگ | 1048576 |
| ۱۶ گیگ و بالاتر | 2097152 |

هر entry حدود ۳۰۰ بایت رم می‌گیرد، و فقط به اندازه‌ی استفاده‌ی واقعی. برای تغییر دستی: `CT_MAX=1048576` (فقط بالا می‌برد، پایین نمی‌آورد).

---

## ۱) سرور نود جدید (Xray/Pasarguard روی داکر)

```bash
# روی سرور خام، قبل از نصب هر چیز دیگر (فایل را طبق بخش «نصب» دانلود کرده باشی)
sudo bash vpn_network_optimizer_v2.1.sh
```

بعدش نود/داکر را نصب کن. نیازی به اجرای دوباره نیست. conntrack از قبل آماده است.

گزینه‌ها:

| گزینه | کار |
|---|---|
| `--role xray` | پیش‌فرض. سرور نود |
| `--role forwarder` | سرور فوروارد (limitهای xray/x-ui را skip می‌کند) |
| `--upgrade` | `apt update` و `dist-upgrade` (پیش‌فرض خاموش) |
| `--reboot` | فقط اگر سیستم بگوید ریبوت لازم است (فقط Ubuntu) |
| `--uninstall` | حذف فایل‌های اسکریپت |

پیش‌فرض: بدون آپگرید، بدون ریبوت، بدون قطع کاربر.

فایل‌هایی که می‌نویسد:

```
/etc/sysctl.d/99-vpn-network-optimizer.conf
/etc/sysctl.d/99-vpn-network-optimizer-ct.conf
/etc/security/limits.d/99-vpn-network-optimizer.conf
/etc/modules-load.d/vpn-network-optimizer.conf    # tcp_bbr + nf_conntrack
/etc/modprobe.d/vpn-network-optimizer.conf        # hashsize
لاگ:   /var/log/vpn-network-optimizer.log
بکاپ:  /root/vpn-network-optimizer-backup/<تاریخ-ساعت>/
```

> توجه: drop-in مربوط به `LimitNOFILE` فقط برای سرویس‌های `xray` و `x-ui` روی خود سیستم است. روی کانتینر داکر اثر ندارد.

## ۲) سرور فوروارد جدید

```bash
sudo bash vpn_network_optimizer_v2.1.sh --role forwarder
sudo sh port-forward-v2.1.sh add 203.0.113.10 443
```

اولین `add` خودش را در `/usr/local/sbin/port-forward` نصب می‌کند و سرویس `port-forward.service` را برای بعد از ریبوت فعال می‌کند. بعد از آن:

| دستور | کار |
|---|---|
| `port-forward add IP PORT` (یا فقط `IP PORT`) | افزودن: پورت لوکال PORT به IP:PORT |
| `port-forward del IP PORT` (یا `del PORT`) | حذف و قطع اتصال‌های زنده |
| `port-forward list` | لیست فوروردها |
| `port-forward status` | وضعیت conntrack و تعداد flow به‌ازای هر پورت |
| `port-forward apply` | اعمال دوباره‌ی قوانین ذخیره‌شده (systemd موقع بوت) |
| `port-forward install` | اعمال قوانین + نصب مجدد اسکریپت و یونیت (بعد از آپدیت فایل) |

قوانین در `/etc/port-forward/rules.conf` ذخیره می‌شوند. متغیر اختیاری: `MSS_CLAMP=0` برای خاموش کردن MSS clamp.

---

## ۳) آپدیت سرورهای فعلی (از v2 به v2.1)

### نودها

```bash
cd /root
curl -fsSL -O https://raw.githubusercontent.com/APX01/VPN-Optimizer/refs/heads/main/vpn_network_optimizer_v2.1.sh
sudo bash vpn_network_optimizer_v2.1.sh
```

چیزی ریستارت نمی‌شود و کاربری قطع نمی‌شود. conntrack همان لحظه روی نود اعمال می‌شود.

### فورواردها

```bash
cd /root
curl -fsSL -O https://raw.githubusercontent.com/APX01/VPN-Optimizer/refs/heads/main/vpn_network_optimizer_v2.1.sh
curl -fsSL -O https://raw.githubusercontent.com/APX01/VPN-Optimizer/refs/heads/main/port-forward-v2.1.sh

sudo bash vpn_network_optimizer_v2.1.sh --role forwarder   # اول این
sudo sh port-forward-v2.1.sh install                       # بعد این
```

`install` فایل `/etc/sysctl.d/99-port-forward.conf` را فقط به `ip_forward` تبدیل می‌کند و فایل قدیمی `modprobe.d/port-forward.conf` را پاک می‌کند، چون مالک conntrack حالا Optimizer است.

اگر `install` را قبل از Optimizer بزنی، خطی از conntrack پاک نمی‌شود (تا ریبوت به پیش‌فرض کرنل برنگردد) و فقط هشدار می‌گیری.

### توصیه

اول روی **یک** نود و **یک** فوروارد اجرا کن، یک بار ریبوت بزن و چک کن (بخش بعد)، بعد روی بقیه.

---

## ۴) بررسی درستی

```bash
sysctl net.netfilter.nf_conntrack_max
cat /sys/module/nf_conntrack/parameters/hashsize     # باید حدود max÷4 باشد
cat /proc/sys/net/netfilter/nf_conntrack_count       # تعداد فعلی
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
lsmod | grep nf_conntrack
cat /etc/modules-load.d/vpn-network-optimizer.conf   # باید nf_conntrack داشته باشد
sysctl net.ipv4.ip_forward                           # فقط فوروارد: باید 1 باشد
```

بعد از ریبوت، مقدار `nf_conntrack_max` باید همان بماند. این تست اصلی v2.1 است.

نشانه‌ی پر شدن جدول:

```bash
dmesg | grep -i "nf_conntrack: table full"
```

اگر چیزی دیدی، `CT_MAX` را بالاتر بگذار و Optimizer را دوباره اجرا کن.

---

## ۵) هشدارها و معنی‌شان

| پیام | معنی و اقدام |
|---|---|
| `nf_conntrack cannot be loaded here` | سرور کانتینر (LXC/OpenVZ) است. conntrack قابل تنظیم نیست، طبیعی است |
| `conntrack tuning not managed yet` (Port-Forward) | Optimizer روی این سرور اجرا نشده. اجرایش کن |
| `nf_conntrack_max=... is low` | مقدار از 262144 کمتر است. Optimizer را دوباره اجرا کن |
| `MISMATCH key ...` | فایل دیگری مقدار را override کرده: `grep -rn KEY /etc/sysctl.conf /etc/sysctl.d /usr/lib/sysctl.d` |
| `BBR is NOT active` | کرنل یا VPS از BBR پشتیبانی نمی‌کند |
| `hashsize is ... (wanted ...)` | با ریبوت بعدی اعمال می‌شود |

---

## ۶) حذف

```bash
sudo bash vpn_network_optimizer_v2.1.sh --uninstall
```

مقدارهای زنده تا ریبوت بعدی می‌مانند. روی نود داکر یا فوروارد حذف کردن یعنی conntrack به پیش‌فرض کرنل برمی‌گردد. Port-Forward اسکریپت uninstall ندارد؛ قوانین را با `del` پاک کن.

---

## ۷) محدودیت‌های شناخته‌شده

- **سقف حدود ۶۴ هزار اتصال همزمان** برای هر (IP نود، پورت، پروتکل) پشت یک فوروارد، به‌خاطر MASQUERADE. برای عبور از آن چند پورت یا چند IP روی نود لازم است.
- نود همه‌ی کاربرهای پشت فوروارد را با **IP فوروارد** می‌بیند.
- Port-Forward برای هر پورت **TCP و UDP** هر دو را فوروارد می‌کند و پورت لوکال و مقصد یکی است.
- این نسخه فقط در محیط شبیه‌سازی (sysctl/modprobe ساختگی) تست شده، نه روی کرنل واقعی. قبل از اجرا روی همه‌ی سرورها، یک سرور تست را با ریبوت بررسی کن.
