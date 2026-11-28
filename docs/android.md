# Phosphor on Android

The phone does not read Claude, Codex, or any other app. Android does not let one app open another app's files, and Phosphor will not work around that. The Mac or Windows app reads usage the way it already does. When you turn phone sync on, it keeps a small snapshot in memory and the phone pulls that snapshot over the Wi-Fi you are both on.

There is no account and no server we run.

## What gets sent

A snapshot is the rows you already see on the desktop: name, plan, percent used, reset countdown, and the burn-rate line. It does not include prompts, replies, API keys, OAuth tokens, file paths, or the desktop's longer error text (those messages sometimes contain a path).

```json
{
  "version": 1,
  "generatedAt": "2026-11-28T12:00:00Z",
  "hostName": "Studio",
  "rows": [
    {
      "id": "claude",
      "name": "Claude Code",
      "monogram": "C",
      "color": "#D97757",
      "plan": "Max",
      "status": "ok",
      "windows": [
        {
          "label": "5H",
          "usedPercent": 62,
          "kind": "quota",
          "resetsIn": "1h 40m",
          "forecastText": "measuring pace",
          "warns": false
        }
      ]
    }
  ]
}
```

The numbers above are the built-in demo shape, not a reading from a real account.

## How pairing works

Phone sync is off until you turn it on. The desktop then listens on your LAN address, port 47321 (or the next free port up to 47330). It shows a QR code and the same facts as text: address, port, and a 6-digit code.

The QR encodes `phosphor://pair?v=1&host=192.168.1.20&port=47321&code=482913`.

1. The phone opens that link, or you type the address and code.
2. The phone sends `POST /v1/pair` with the code.
3. The desktop checks the code, burns it so it cannot be used again, and returns a long random token.
4. The phone stores the token and calls `GET /v1/snapshot` with `Authorization: Bearer …`.

The code lasts 10 minutes. A second phone needs a new code. Tokens are remembered on the desktop so the phone stays paired after a restart. Turning sync off stops the listener. "Forget phones" drops the tokens.

`GET /v1/health` answers without a token and without usage, so the phone can see that it reached Phosphor.

The listener binds to all interfaces so a phone on the same Wi-Fi can connect. It is plain HTTP. A pairing token is the only check. Someone on that same Wi-Fi who can see the packets can read the snapshot and the token. Use a network you trust. The desktop firewall may ask you to allow incoming connections the first time.

## Why this and not something else

| Approach | Why it was not the default |
|---|---|
| Same-Wi-Fi pull (this one) | No account, no server, nothing to pay for. Both devices have to be on together. Cleartext on the LAN is the cost. |
| A relay you choose (later) | Would work away from home. It needs a host you run, or a public relay that would see the snapshot. Not built. |
| An account on a Phosphor server | Easy when you are out, and it means we would hold usage data. That is the opposite of how Phosphor is set up. |
| The phone reading the CLIs itself | Android will not allow it without special access, and we will not collect cookies or credentials to fake it. |
| Bluetooth | More pairing pain for a payload that is a few kilobytes of JSON. |
| A file in cloud storage you pick | Possible later. It depends on whatever app you use to sync the file, and it is easy to leave a snapshot sitting in a folder. |

A relay stays a possible follow-up: you would point both apps at an address you control, and the same token would travel over HTTPS. It is not in this version.

## The Android app

The home screen needs a real app widget. Tauri's mobile shell does not provide one, so the phone app is Kotlin. Jetpack Glance draws the widget, and Jetpack Compose draws the screen inside the app. The widget and the screen share one snapshot stored on the phone.

The screen can follow the system language or stay in English or Korean. Three looks are built in (Clean, Matrix, Retro), close to the desktop themes of the same names. The full theme JSON files are still desktop-only.

The widget refreshes when you open the app, when you tap refresh on the widget, and about every 15 minutes while the phone is awake. WorkManager will not do better than that in the background, and it will not refresh at all if the desktop app is quit or the phone is on another network. The widget then keeps the last snapshot and shows its age.

A Demo switch on the phone fills the screen and the widget with the sample snapshot. It does not use the network. That is what screenshots should use.

## Desktop switch

Mac: the menu item **Phone sync (same Wi-Fi)**. Windows: the **Phone sync** checkbox on the HUD. Both default to off. The Mac app speaks the same HTTP rules in Swift. The Windows app uses the Rust server in `phosphor-core`. A unit test on each side checks pairing, rejection of a bad code, and that a snapshot request without the token is refused.
