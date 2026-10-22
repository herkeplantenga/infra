{
  # Mail for the Plantenga family on beta, via Simple NixOS Mailserver.
  #
  # mail.plantenga.net is the server name (PTR of beta's IPv4 already points
  # there). plantenga.com is the primary domain: every mailbox is
  # <user>@plantenga.com. plantenga.net/.org/.eu are family alias domains:
  # <user>@<domain> lands in, and may be sent as by, <user>@plantenga.com.
  # ruvinian.com/.eu/.net only carry herke@ (plus postmaster/abuse/dmarc ->
  # herke). Aliases are explicit (no catch-all) to keep spam out.
  #
  # Password hashes stay off the nix store. Create one file per account on the
  # host before deploying (root, 0600), e.g. for herke:
  #   install -d -m 700 /root/secrets/mail
  #   (umask 077; mkpasswd -s -m yescrypt > /root/secrets/mail/herke.hash)
  #
  # DKIM keys are generated on first start in /var/dkim; publish
  # /var/dkim/<domain>.mail.txt as mail._domainkey.<domain> TXT.
  #
  # Caveat until plantenga.com's MX moves here: beta treats plantenga.com as
  # local, so mail sent through beta to @plantenga.com stays on beta instead of
  # reaching the mailboxes at Oxilion.
  den.aspects.mailserver.nixos =
    { config, inputs, lib, ... }:
    let
      fqdn = "mail.plantenga.net";
      primary = "plantenga.com";
      # Family domains: every user gets <user>@<domain>.
      familyAliasDomains = [
        "plantenga.net"
        "plantenga.org"
        "plantenga.eu"
      ];
      # Ruvinian domains belong to herke only.
      herkeOnlyDomains = [
        "ruvinian.com"
        "ruvinian.eu"
        "ruvinian.net"
      ];
      allDomains = [ primary ] ++ familyAliasDomains ++ herkeOnlyDomains;

      # user -> per-account settings. Quota falls back to quota.defaults.perUser.
      users = {
        herke = {
          quota = "10G";
          extraAliases =
            map (d: "herke@${d}") herkeOnlyDomains
            # RFC 2142 role addresses and DMARC reports for every domain go here.
            ++ lib.concatMap (d: [
              "postmaster@${d}"
              "abuse@${d}"
              "dmarc@${d}"
            ]) allDomains;
        };
        hiele = {
          extraAliases = [ "info@${primary}" ];
        };
        pieter = { };
        roan = { };
        ruben = { };
        viggo = { };
        yannick = { };
      };

      mkAccount = user: u: {
        name = "${user}@${primary}";
        value = {
          hashedPasswordFile = "/root/secrets/mail/${user}.hash";
          aliases = map (d: "${user}@${d}") familyAliasDomains ++ (u.extraAliases or [ ]);
        }
        // lib.optionalAttrs (u ? quota) { inherit (u) quota; };
      };
    in
    {
      imports = [ inputs.simple-nixos-mailserver.nixosModules.default ];

      mailserver = {
        enable = true;
        stateVersion = 5; # fresh install on the 26.05 release; never lower this
        inherit fqdn;
        domains = allDomains;
        systemDomain = primary;
        systemContact = "postmaster@${primary}";

        accounts = lib.mapAttrs' mkAccount users;
        quota.defaults.perUser = "2G";
        messageSizeLimit = 50 * 1024 * 1024; # 50 MB

        # Ports: 25 (MX), 465 + 587 (submission), 993 (IMAPS). No plaintext 143/110.
        enableImap = false;
        enableImapSsl = true;
        enableSubmission = true;
        enableSubmissionSsl = true;
        enablePop3 = false;
        enablePop3Ssl = false;
        enableManageSieve = false;
        openFirewall = true;

        # Cert for mail.plantenga.net comes from the nginx vhost below.
        x509.useACMEHost = fqdn;
      };

      # No IPv6 on this host; avoids delivery stalls on AAAA-first MXes
      # (gmail-smtp-in fails over v6 from beta, works over v4).
      services.postfix.settings.main.inet_protocols = lib.mkForce "ipv4";

      # rspamd's DNS blocklists (Spamhaus etc.) refuse queries relayed through
      # 1.1.1.1/8.8.8.8, which is what systemd-resolved on beta forwards to.
      # Point rspamd at SNM's local recursive kresd instead.
      services.rspamd.locals."options.inc".text = ''
        dns {
          nameserver = ["127.0.0.1:53"];
        }
      '';

      # Only here to get the ACME cert via HTTP-01; nothing is served.
      services.nginx = {
        enable = true;
        virtualHosts.${fqdn} = {
          enableACME = true;
          forceSSL = true;
          locations."/".return = "404";
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
