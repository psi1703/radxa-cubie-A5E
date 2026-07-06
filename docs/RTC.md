# ⏱ RTC Sync Module

This module installs **RTC detection and synchronization**.

---

## 🧠 What It Does

- Detects DS3231 on I2C
- Binds kernel driver if needed
- Creates:
  - rtc-sync.sh
  - rtc-sync.service
  - rtc-sync.timer
- Keeps:
  - System time
  - RTC
  - COPILOT time
  in sync

---

## 🧱 Architecture

```
RTC ⇄ System Time ⇄ COPILOT
```

---

## 🧪 Manual Run

```bash
/usr/local/bin/rtc-sync.sh
```

---

## 🧠 Mental Model

> This is the **timekeeper of the box**.
