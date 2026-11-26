# Security

## Trust model

The archive (`archive.sqlite`, `media/`, `people.sqlite`) is plain files. Anyone who can read the folder can read every message in it. Keep it on an encrypted disk and out of synced or shared folders you do not control.

`archivectl` and the Mac app never send the archive anywhere. The only network listeners are the two you start:

- `archivectl serve` (the review site for merging people) answers loopback peers only and checks the `Origin` of every write.
- `archivectl serve-web` (the read-only web app) answers loopback only unless told otherwise.

**The web app has no user accounts.** It decides only whether a request comes from somewhere allowed:

1. **Peer.** Loopback is always allowed. Any other peer must be listed with `--allow-peer`, or `--any-peer` is given (in a container, where the port mapping is the boundary).
2. **Host.** The `Host` header must be a loopback name or a name given with `--allow-host`.
3. **Key.** Every request from a non-loopback peer must carry `X-Archive-Key` equal to `$ARCHIVE_WEB_KEY`, compared in constant time. With no key configured, only loopback peers are served.
4. **Tailscale login.** With `--allow-login`, a proxied request must carry a `Tailscale-User-Login` header naming a listed login. This is honored only on a loopback bind behind `tailscale serve`, which sets that header itself; anywhere else a client could send it.

`serve-web` refuses to start with a gate that fails open: a non-loopback bind without a key of at least 24 characters (the example placeholder is refused), `--allow-login` on a non-loopback bind, or `--allow-host` on loopback with neither a key nor `--allow-login`. An empty `ARCHIVE_WEB_KEY` counts as no key.

**The key is not user authentication.** A reverse proxy that adds the key to every request makes the archive available to everyone who can reach the proxy. Whatever exposes the web app (a reverse proxy, a VPN, `tailscale serve`) must authenticate the people using it. Loopback peers need no key, so a proxy on the same machine is trusted completely: it must do the authenticating.

## Attachments

Messages carry files other people sent. The web app serves them from its own origin, so it never lets one run as the app: only images, audio, video and plain text are sent inline; HTML, SVG, XML, scripts, PDFs and anything unknown go out as `application/octet-stream` downloads. Every attachment and thumbnail is sent with `X-Content-Type-Options: nosniff` and `Content-Security-Policy: sandbox; default-src 'none'; ...`, and the app's own pages carry a strict CSP. API calls need an `X-Requested-With` header that a cross-site form or image cannot send.

## Updates

The Mac app's self-updater is off unless an https update server is configured. When it is on, it checks a build in this order: the downloaded zip must match the published size and SHA-256 (before anything is unpacked); it is then unpacked with `ditto` into a private staging folder beside the installed app, must hold exactly one app bundle with the running app's identifier and the published build number, and that bundle's code signature must pass strict validation and satisfy the running app's own designated requirement (same identifier, same certificate leaf). Only then is anything installed. A code signature cannot be checked inside a zip, so unpacking comes before the signature check; nothing unpacked runs or is installed before it passes.

The updater sends only the web app's `X-Requested-With` header, no credentials, so it cannot get past a proxy that authenticates people with basic auth or SSO. It works when the update server is reached over `tailscale serve` with `--allow-login` (Tailscale identifies the Mac), or over a network path you trust without a login.

## Reporting a problem

Please report security problems privately through the repository host's security advisory feature rather than a public issue.
