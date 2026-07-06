# 📶 Hotspot Module

This module turns the box into a **WiFi access point** for field access.

---

## 🧠 What It Does

- Installs: hostapd, dnsmasq, dhcpcd
- Creates SSID: `initbox_<BOXNO>`
- Provides DHCP + DNS
- Isolated from br0

---

## 🧱 Architecture

```
Laptop → WiFi → wlan0 → Host → SSH / Dashboard
```

---

## 🔁 Runtime

- SSID example: `initbox_3`
- IP example: `192.168.40.3`
- Password is set in environment or script

---

## 🧠 Mental Model

> This is the **maintenance port of the appliance**.
