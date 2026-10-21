{
  # Latency graphs for https://smokeping.plantenga.net, from beta (AS24875).
  # Nixpkgs' smokeping module runs the daemon as the unprivileged smokeping
  # user and is the only thing that installs a setuid fping wrapper. Its
  # webService also creates virtualHosts."smokeping" with no auth, on plain
  # HTTP, serverName defaulting to localhost. This aspect keeps that vhost
  # (it owns the fcgiwrap socket and the CGI locations) and turns it into the
  # public HTTPS vhost. Do not add a second one.
  #
  # There is no sops/agenix in this repo. Other apps read a root-owned env
  # file created on the host (/etc/website.env and friends). The Google OAuth
  # web client JSON is already on beta at
  # /root/secrets/smokeping-google-oauth.json (root:root, 0600). A oneshot
  # derives oauth2-proxy's env file from it and, once, a cookie secret.
  # Neither file is in the nix store. The NovoServe logo is used with
  # NovoServe's (Herke's) permission.
  den.aspects.smokeping.nixos =
    { config, lib, pkgs, ... }:
    let
      domain = "smokeping.plantenga.net";
      secretDir = "/var/lib/oauth2-proxy-smokeping";
      secretEnv = "${secretDir}/env";
      # Strings, not path literals: a path would be copied into the nix store.
      oauth2Proxy = "127.0.0.1:4180";

      # Runs before oauth2-proxy. systemd reads the env file as root, so it
      # can stay 0600 root:root and the service user never opens it.
      deriveOauth2ProxySecrets = pkgs.writeShellScript "oauth2-proxy-smokeping-secrets" ''
        set -euo pipefail
        export PATH="${
          lib.makeBinPath [
            pkgs.coreutils
            pkgs.jq
            pkgs.openssl
          ]
        }"

        src=/root/secrets/smokeping-google-oauth.json
        dir=${secretDir}
        cookie="$dir/cookie-secret"
        envfile="$dir/env"
        redirect=https://${domain}/oauth2/callback

        if [[ ! -f $src ]]; then
          echo "oauth2-proxy-smokeping-secrets: missing $src" >&2
          echo "Place the Google OAuth web client JSON there (root:root, mode 0600). Never commit it." >&2
          exit 1
        fi

        install -d -m 0700 -o root -g root "$dir"

        mode=$(stat -c %a "$src")
        owner=$(stat -c %U:%G "$src")
        if [[ $mode != 600 && $mode != 400 ]]; then
          echo "oauth2-proxy-smokeping-secrets: warning: $src is mode $mode, expected 0600" >&2
        fi
        if [[ $owner != root:root ]]; then
          echo "oauth2-proxy-smokeping-secrets: warning: $src is owned by $owner, expected root:root" >&2
        fi

        # 32 bytes, base64url without padding. oauth2-proxy accepts that as an
        # AES key. Generated once; deleting the file rotates it and logs everyone out.
        if [[ ! -s $cookie ]]; then
          umask 077
          openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n' > "$cookie"
        fi
        chmod 0600 "$cookie"
        chown root:root "$cookie"

        cookie_secret=$(tr -d '\n' < "$cookie")
        if [[ -z $cookie_secret || $cookie_secret == *[[:space:]]* ]]; then
          echo "oauth2-proxy-smokeping-secrets: $cookie is empty or contains whitespace; delete it to regenerate" >&2
          exit 1
        fi

        client_id=$(jq -er '.web.client_id' "$src")
        client_secret=$(jq -er '.web.client_secret' "$src")
        if [[ -z $client_id || -z $client_secret || $client_id == *$'\n'* || $client_secret == *$'\n'* ]]; then
          echo "oauth2-proxy-smokeping-secrets: .web.client_id or .web.client_secret missing or unusable in $src" >&2
          exit 1
        fi

        if jq -e '.web.redirect_uris' "$src" >/dev/null; then
          if ! jq -e --arg u "$redirect" '(.web.redirect_uris // []) | index($u)' "$src" >/dev/null; then
            echo "oauth2-proxy-smokeping-secrets: warning: $src redirect_uris does not list $redirect" >&2
          fi
        fi

        escape() {
          local s="$1"
          s=''${s//\\/\\\\}
          s=''${s//\"/\\\"}
          printf '%s' "$s"
        }

        umask 077
        tmp=$(mktemp "$dir/.env.XXXXXX")
        {
          printf 'OAUTH2_PROXY_CLIENT_ID="%s"\n' "$(escape "$client_id")"
          printf 'OAUTH2_PROXY_CLIENT_SECRET="%s"\n' "$(escape "$client_secret")"
          printf 'OAUTH2_PROXY_COOKIE_SECRET="%s"\n' "$(escape "$cookie_secret")"
        } > "$tmp"
        chmod 0600 "$tmp"
        chown root:root "$tmp"
        mv -f "$tmp" "$envfile"
      '';

      # Every location that serves SmokePing. /oauth2/ is the proxy's own
      # endpoints, and nginx's ACME location turns auth_request off itself.
      authRequest = ''
        auth_request /oauth2/auth;
        auth_request_set $smokeping_user $upstream_http_x_auth_request_email;
        auth_request_set $auth_cookie $upstream_http_set_cookie;
        error_page 401 = /oauth2/sign_in;

        add_header Set-Cookie $auth_cookie;
        add_header X-Robots-Tag "noindex, nofollow" always;
        add_header X-Frame-Options "DENY" always;
        add_header X-Content-Type-Options "nosniff" always;
      '';
    in
    {
      services.smokeping = {
        enable = true;
        hostName = domain;
        # Becomes the nginx serverName (the module default is "localhost").
        host = domain;
        webService = true;
        cgiUrl = "https://${domain}/smokeping.fcgi";
        owner = "Herke Plantenga";
        ownerEmail = "noc@plantenga.net";
        presentationTemplate = "${./smokeping/basepage.html}";

        # 4032*300s = 14d raw; 4320*1h = 180d; 1440*12h = 720d (~2y).
        # NOTES asked for about 4 years of 12h data; the reference sketch set
        # 1440. Left that way so it can be changed before the first deploy.
        # Changing step, pings, or these rows later means replacing the RRDs.
        databaseConfig = ''
          step     = 300
          pings    = 20

          AVERAGE  0.5   1  4032
          AVERAGE  0.5  12  4320
              MIN  0.5  12  4320
              MAX  0.5  12  4320
          AVERAGE  0.5 144  1440
              MAX  0.5 144  1440
              MIN  0.5 144  1440
        '';

        # One fping for the whole list, pings to a host 1.5s apart so ISP
        # resolvers don't treat the round as a burst. IPv4 only: beta has no
        # IPv6 address. The binary is the setuid wrapper the smokeping module
        # installs; the daemon itself stays unprivileged.
        probeConfig = ''
          + FPing
          binary = ${config.security.wrapperDir}/fping
          mininterval = 0.01
          hostinterval = 1.5
          timeout = 1.5
        '';

        targetConfig = builtins.readFile ./smokeping/targets.conf;
      };

      # The CGI process caches the template. Restart it when that config changes.
      systemd.services.fcgiwrap-smokeping.restartTriggers = [
        config.environment.etc."smokeping.conf".source
      ];

      systemd.services.smokeping = {
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
      };

      # nginx auth_request in front of the CGI. oauth2-proxy is not the
      # reverse proxy for SmokePing; it only answers /oauth2/.
      services.oauth2-proxy = {
        enable = true;
        provider = "google";
        # Client id and secret come from the derived env file, not from here.
        keyFile = secretEnv;
        redirectURL = "https://${domain}/oauth2/callback";
        email.domains = [ "novoserve.com" ];
        # Internal Workspace consent: don't force the consent screen every login.
        approvalPrompt = "auto";
        setXauthrequest = true;
        # nginx is the proxy. Don't have oauth2-proxy invent basic auth.
        passBasicAuth = false;
        reverseProxy = true;
        trustedProxyIP = [ "127.0.0.1" ];
        httpAddress = "http://${oauth2Proxy}";
        # No upstream app. Requests outside /oauth2/ are not sent here.
        upstream = [ "static://202" ];
        extraConfig."skip-provider-button" = true;
        cookie.secure = true;
      };

      systemd.services.oauth2-proxy-smokeping-secrets = {
        description = "Derive oauth2-proxy credentials for SmokePing";
        requiredBy = [ "oauth2-proxy.service" ];
        before = [ "oauth2-proxy.service" ];
        serviceConfig = {
          Type = "oneshot";
          # Inactive after success, so a restart of oauth2-proxy runs it again
          # and picks up a replaced client JSON. The cookie secret file is kept.
          RemainAfterExit = false;
          UMask = "0077";
          StateDirectory = "oauth2-proxy-smokeping";
          StateDirectoryMode = "0700";
          ExecStart = deriveOauth2ProxySecrets;
        };
      };

      systemd.services.oauth2-proxy = {
        after = [ "oauth2-proxy-smokeping-secrets.service" ];
        requires = [ "oauth2-proxy-smokeping-secrets.service" ];
        serviceConfig.RestartSec = "5s";
      };

      services.nginx = {
        enable = true;
        recommendedProxySettings = true;
        recommendedTlsSettings = true;
        recommendedGzipSettings = true;
        virtualHosts.smokeping = {
          serverName = domain;
          enableACME = true;
          forceSSL = true; # :80 is only the ACME challenge and a redirect to HTTPS
          extraConfig = ''
            add_header X-Robots-Tag "noindex, nofollow" always;
            add_header X-Frame-Options "DENY" always;
            add_header X-Content-Type-Options "nosniff" always;
          '';
          locations."/" = {
            extraConfig = authRequest;
          };
          locations."/smokeping.fcgi" = {
            extraConfig = lib.mkAfter ''
              ${authRequest}
              fastcgi_param REMOTE_USER $smokeping_user;
            '';
          };
          locations."/brand/" = {
            extraConfig = ''
              alias ${./smokeping/static}/;
              ${authRequest}
              expires 7d;
              add_header Cache-Control "public";
            '';
          };
          locations."/oauth2/" = {
            proxyPass = "http://${oauth2Proxy}";
            extraConfig = ''
              proxy_set_header X-Scheme $scheme;
              proxy_set_header X-Auth-Request-Redirect $request_uri;
            '';
          };
          locations."= /oauth2/auth" = {
            proxyPass = "http://${oauth2Proxy}";
            extraConfig = ''
              proxy_set_header X-Scheme $scheme;
              proxy_set_header Content-Length "";
              proxy_pass_request_body off;
            '';
          };
        };
      };

      security.acme = {
        acceptTerms = true;
        defaults.email = "me@yanpla.nl";
      };

      # Already opened by the other vhosts on beta. Repeated so this aspect
      # still serves ACME and HTTPS if it is ever included on its own.
      networking.firewall.allowedTCPPorts = [
        80
        443
      ];
    };
}
