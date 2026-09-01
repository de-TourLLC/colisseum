# Colisseum Runtime Error Codes

Obfuscated output never reports failures in plain text. When a protection guard
fires at runtime, it raises a branded, deliberately opaque message:

```
ᴄᴏʟɪѕѕᴇᴜᴍ ︱ Oh Noes!, An error ocurred: <CODE>
```

The code reveals nothing to a reverse engineer. Look it up here to understand
what happened.

| Code     | Guard              | Meaning |
| -------- | ------------------ | ------- |
| `0x7A31` | anti-tamper        | The runtime environment failed the tamper/executor checks: a debug hook, replaced core globals, executor/injector signatures or markers, an abnormal `_G` metatable, environment divergence, or a timing anomaly pushed the suspicion score past the threshold. |
| `0x5C08` | runtime-integrity  | A core function (`type`, `pcall`, `error`, `tostring`) was replaced, a debug hook was installed, or the embedded self-consistency nonce did not hash to its expected value. |
| `0x3E9D` | crypto integrity   | The decrypted payload did not match its checksum — the encrypted array was corrupted or tampered with. |
| `0x3E9E` | crypto load        | The decrypted chunk did not compile — corruption, or an incompatible runtime/dialect. |
| `0x2B14` | vm load            | The keystream-decoded chunk did not compile — corruption, or an incompatible runtime/dialect. |

Notes:
- A `0x7A31` or `0x5C08` almost always means the script was moved into an
  executor / injector or is being debugged. In the intended runtime these guards
  score zero and never fire.
- A `0x3E9D` / `0x3E9E` / `0x2B14` means the protected bytes were altered after
  the build, or the output is being run on a runtime it was not built for.
