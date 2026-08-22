# Security Policy

## Supported versions

Pupa ships patch-only `0.0.X` releases and follows the latest published
version. Security fixes land on the latest release; please upgrade before
reporting.

## Reporting a vulnerability

**Please do not open a public GitHub issue for security problems.**

Report privately via either channel:

- GitHub's [private vulnerability reporting](https://github.com/pupa-app/pupa/security/advisories/new)
  ("Report a vulnerability" under the repository's **Security** tab), or
- email **support@pupa-app.com**.

We aim to acknowledge a report within a few days and will coordinate a fix and
disclosure timeline with you.

When reporting, please include the app version (Settings → About), the
platform, and steps to reproduce or a proof of concept if you have one.

## Scope and design notes

Pupa is a native client for a backend **the user runs themselves**. A few
properties shape what is and isn't a vulnerability here:

- **No secrets ship in the app.** It holds one credential — the paired-device
  token — in the Keychain (`kSecAttrAccessibleAfterFirstUnlock`). LLM and cloud
  keys live in the operator's backend environment and never reach a client.
- **The client talks to its configured backend**, plus `raw.githubusercontent.com`
  for marketplace bundle downloads (allow-listed by path and checksum-verified)
  and a public STUN server during screen-share. It will also load images by URL
  from card and markdown content — that content is normally the user's own or
  their agent's, and for **imported** apps it's off until the user allows it.
- **No web view.** Nothing renders untrusted HTML or JavaScript — markdown is
  parsed and rendered as SwiftUI views, never as a web document — so there is
  no script execution surface.
- **App Transport Security forbids arbitrary loads.** A public backend must be
  HTTPS; plaintext is permitted only for loopback and local networking, so a
  LAN or offline self-host still works.

### Imported `.pupa` bundles are untrusted

A bundle is authored by whoever published it, so import treats its contents as
hostile and the confirm sheet is the gate. Specifically: settings are
allow-listed, memory writes are confined to the app's own subtree with `..` and
absolute paths rejected and extensions limited to `.md` / `.json`, automation
rules are forced to *propose* rather than fire on their own, remote image
loading is off until the user turns it on, and link fields accept only
`http`/`https` plus in-app `pupa://` (which the app intercepts itself and never
hands to the OS).

What that does **not** cover, by design: an imported agent prompt or skill body
is model-facing text, and a bundle that ships one is asking the model to behave
a certain way. Treat installing a bundle like running someone else's
configuration — see [docs/marketplace.md](docs/marketplace.md) for the full
threat model.

Please flag any finding that weakens these properties (token leakage, a bundle
escaping its memory subtree or reaching the network unprompted, a scheme that
reaches the OS from untrusted content) through the private channel above.
