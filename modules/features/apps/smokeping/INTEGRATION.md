# NovoServe theme for services.smokeping

Checked against nixpkgs `nixos-26.05` (`nixos/modules/services/networking/smokeping.nix`, smokeping 2.9.0). The aspect that loads this directory is `../smokeping.nix`.

## What the module gives you

- `services.smokeping.presentationTemplate` is `template =` under `*** Presentation ***`. This directory's `basepage.html` is that template. The default would be the package's `basepage.html.dist`.
- The module symlinks the package's `css/`, `js/` and `smokeping.fcgi` into `/var/lib/smokeping` and uses that directory as the nginx root. It has no option for extra CSS, fonts, or logos, so `static/` is served at `/brand/` by nginx.
- `imgUrl` (default `cache`) and `imgcache` are only for the generated graphs. Leave both alone.

## Files

```
smokeping/
  basepage.html     presentationTemplate
  static/           served at /brand/ (behind the same Google SSO as the graphs)
    novoserve.css
    fonts/          Poppins 400/600/700, Carlito 400/700 (woff2) and their OFL texts
    img/            novoserve-logo-green.svg (the one the template uses), plus navy, png, favicon
  targets.conf      the probe tree (what SmokePing loads)
  targets.yaml      the source list targets.conf was generated from
```

The template loads the stock `css/smokeping-screen.css` first, then `/brand/novoserve.css`, which only overrides it. The stock ids and classes stay, so the sidebar, auto-refresh, and zoom scripts keep working. All 13 stock placeholders are present. The page makes no external requests.

The NovoServe logo is used with NovoServe's (Herke's) permission.

## Auth

The vhost is `services.nginx.virtualHosts.smokeping` (the one the module creates). `enableACME` and `forceSSL` make port 80 a redirect plus the ACME challenge. Google SSO is oauth2-proxy, via `auth_request`, for `/`, `/smokeping.fcgi`, and `/brand/`. `/oauth2/` is proxied to oauth2-proxy without `auth_request`. The ACME location sets `auth_request off` itself.

`basicAuthFile` is not used. Login is limited to `@novoserve.com`.

## Template caching

SmokePing reads the template when the CGI starts. The aspect restarts `fcgiwrap-smokeping` when `smokeping.conf` changes. If an old page sticks, `systemctl restart fcgiwrap-smokeping.service` on the host.

`<##smokelogo##>` and `<##rrdlogo##>` point at images the nixpkgs package does not ship. The template keeps the placeholders and the CSS hides them.

The `<title>` and the top bar are hardcoded to "NovoServe Network Latency". The H1 is the current target's `title`.
