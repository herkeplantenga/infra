{
  # Serves smokeping.plantenga.net behind Google SSO (novoserve.com only).
  # Needs the Google OAuth client JSON on the host at
  # /root/secrets/smokeping-google-oauth.json (root, 0600).
  den.aspects.smokeping.nixos =
    { config, pkgs, ... }:
    let
      domain = "smokeping.plantenga.net";
      oauth2Proxy = "http://127.0.0.1:4180";
      stateDir = "/var/lib/oauth2-proxy-smokeping";

      deriveSecrets = pkgs.writeShellApplication {
        name = "oauth2-proxy-smokeping-secrets";
        runtimeInputs = [
          pkgs.jq
          pkgs.openssl
        ];
        text = ''
          src=/root/secrets/smokeping-google-oauth.json
          cd ${stateDir}
          [[ -s cookie-secret ]] || openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n' > cookie-secret
          id=$(jq -er .web.client_id "$src")
          secret=$(jq -er .web.client_secret "$src")
          printf 'OAUTH2_PROXY_CLIENT_ID=%s\nOAUTH2_PROXY_CLIENT_SECRET=%s\nOAUTH2_PROXY_COOKIE_SECRET=%s\n' \
            "$id" "$secret" "$(cat cookie-secret)" > ./env
        '';
      };
    in
    {
      services.smokeping = {
        enable = true;
        hostName = domain;
        host = domain;
        webService = true;
        cgiUrl = "https://${domain}/smokeping.fcgi";
        owner = "Herke Plantenga";
        ownerEmail = "noc@novoserve.com";
        presentationTemplate = "${./smokeping/basepage.html}";

        # 14d at 5m, 180d at 1h, 2y at 12h. Changing this later means deleting the RRDs.
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

        probeConfig = ''
          + FPing
          binary = ${config.security.wrapperDir}/fping
          mininterval = 0.01
          hostinterval = 1.5
          timeout = 1.5
        '';

        targetConfig = builtins.readFile ./smokeping/targets.conf;
      };

      # The CGI caches the template.
      systemd.services.fcgiwrap-smokeping.restartTriggers = [
        config.environment.etc."smokeping.conf".source
      ];

      services.oauth2-proxy = {
        enable = true;
        provider = "google";
        keyFile = "${stateDir}/env";
        redirectURL = "https://${domain}/oauth2/callback";
        email.domains = [ "novoserve.com" ];
        approvalPrompt = "auto";
        setXauthrequest = true;
        reverseProxy = true;
        upstream = [ "static://202" ];
        extraConfig."skip-provider-button" = true;
      };

      systemd.services.oauth2-proxy-smokeping-secrets = {
        requiredBy = [ "oauth2-proxy.service" ];
        before = [ "oauth2-proxy.service" ];
        serviceConfig = {
          Type = "oneshot";
          UMask = "0077";
          StateDirectory = "oauth2-proxy-smokeping";
          ExecStart = "${deriveSecrets}/bin/oauth2-proxy-smokeping-secrets";
        };
      };

      services.nginx = {
        enable = true;
        recommendedProxySettings = true;
        recommendedTlsSettings = true;
        recommendedGzipSettings = true;
        # The smokeping module creates this vhost; it only adds TLS and auth here.
        virtualHosts.smokeping = {
          enableACME = true;
          forceSSL = true;
          extraConfig = ''
            auth_request /oauth2/auth;
            auth_request_set $smokeping_user $upstream_http_x_auth_request_email;
            auth_request_set $auth_cookie $upstream_http_set_cookie;
            error_page 401 = /oauth2/sign_in;
            add_header Set-Cookie $auth_cookie;
            add_header X-Robots-Tag "noindex, nofollow" always;
          '';
          locations."/smokeping.fcgi".extraConfig = ''
            fastcgi_param REMOTE_USER $smokeping_user;
          '';
          locations."/brand/".alias = "${./smokeping/static}/";
          locations."/oauth2/" = {
            proxyPass = oauth2Proxy;
            extraConfig = ''
              auth_request off;
              proxy_set_header X-Scheme $scheme;
              proxy_set_header X-Auth-Request-Redirect $request_uri;
            '';
          };
          locations."= /oauth2/auth" = {
            proxyPass = oauth2Proxy;
            extraConfig = ''
              auth_request off;
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

      networking.firewall.allowedTCPPorts = [
        80
        443
      ];
    };
}
