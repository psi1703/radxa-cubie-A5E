# 🧱 A5E Base Module

This is the **foundation module**. Everything depends on this.

---

## 🧠 What It Does

- Forces headless mode
- Removes GUI packages
- Fixes broken dpkg state
- Creates `initbox` user
- Migrates installer to `/home/initbox`
- Sets hostname
- Sets baseline OS state

---

## 🧱 Architecture

```
Factory Image
     │
     ▼
  A5E Module
     │
     ▼
 Appliance OS
```

---

## ⚠️ Must Be Run First

All other modules assume:

- `initbox` exists
- Home directory exists
- Logging path exists

---

## 🧠 Mental Model

> This is the **OS transformer**.
