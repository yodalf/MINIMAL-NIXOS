# Headscale: self-hosted Tailscale coordination server.
#
# Everything that is specific to this machine's role lives here; server.nix
# stays a generic minimal Vultr box.
#
# Public name: hs.realo.ca (A record at Dyn -> 104.238.132.193). TLS comes
# from Let's Encrypt via headscale's built-in ACME client (HTTP-01 on port
# 80); the certificate is cached in /var/lib/headscale/.cache and renewed
# automatically. See "Using it" at the bottom.
{ config, lib, pkgs, ... }:

let
  # Public name clients connect to (https://<fqdn>).
  fqdn = "hs.realo.ca";
  # MagicDNS suffix for nodes (<node>.<baseDomain>), tailnet-internal only.
  # Must not be the same as, or a parent of, the server's own domain.
  baseDomain = "ts.realo.ca";
in
{
  networking.hostName = "headscale";

  services.headscale = {
    enable = true;
    # Public HTTPS listener (the module grants CAP_NET_BIND_SERVICE for <1024).
    address = "0.0.0.0";
    port = 443;

    settings = {
      server_url = "https://${fqdn}";

      dns = {
        magic_dns = true;
        base_domain = baseDomain;
        override_local_dns = true;
        nameservers.global = [ "1.1.1.1" "1.0.0.1" ];
      };

      # Public Tailscale DERP relays; no embedded DERP server on a 512 MB box.
      derp.urls = [ "https://controlplane.tailscale.com/derpmap/default" ];
      derp.auto_update_enabled = true;

      database.type = "sqlite";
      log.level = "info";

      # Without this headscale chmods its CLI socket to 0700 and only root
      # can use the CLI; 0770 lets the headscale group (realo) use it.
      unix_socket_permission = "0770";

      # Let's Encrypt via HTTP-01: headscale answers the challenge on port 80
      # itself. Let's Encrypt allows 5 failed validations per hostname per
      # hour, so the A record must exist before this starts.
      tls_letsencrypt_hostname = fqdn;
      tls_letsencrypt_challenge_type = "HTTP-01";
      tls_letsencrypt_listen = ":http";
      # Alternative, a certificate from elsewhere (readable by headscale):
      # tls_cert_path = "/var/lib/headscale/tls/fullchain.pem";
      # tls_key_path = "/var/lib/headscale/tls/privkey.pem";
    };
  };

  # 80 for the ACME HTTP-01 challenge, 443 for clients.
  networking.firewall.allowedTCPPorts = [ 80 443 ];

  # Let realo run `headscale users create …` etc. without sudo: the CLI talks
  # to the unix socket in /run/headscale, which is group-readable.
  users.users.realo.extraGroups = [ "headscale" ];

  ### Backup #################################################################

  # Daily snapshot of /var/lib/headscale into /var/backups/headscale (30 kept,
  # ~100 KB each): the SQLite db via the online backup API (consistent while
  # headscale runs; never copy the raw file), the noise private key (server
  # identity every client pinned; without it or the db every node must be
  # re-registered) and the ACME cache. The server cannot reach the Mac or the
  # dev VM, so this is pulled from the Mac with `build.sh backup`.
  #
  # Restore: systemctl stop headscale; rm -rf /var/lib/headscale/*;
  #          tar -C /var/lib -xzf <snapshot>; chown -R headscale:headscale /var/lib/headscale
  #          systemctl start headscale
  systemd.services.headscale-backup = {
    description = "Snapshot /var/lib/headscale";
    # After the nightly gc (00:00) and before the nightly upgrade (04:40).
    startAt = "03:00";
    path = [ pkgs.sqlite pkgs.gnutar pkgs.gzip pkgs.coreutils pkgs.findutils ];
    serviceConfig.Type = "oneshot";
    script = ''
      src=/var/lib/headscale
      dir=/var/backups/headscale
      stamp=$(date -u +%Y%m%d-%H%M%S)
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

      cp -a "$src" "$work/headscale"
      rm -f "$work"/headscale/db.sqlite*
      sqlite3 "$src/db.sqlite" ".backup '$work/headscale/db.sqlite'"
      chmod 600 "$work/headscale/db.sqlite"

      mkdir -p "$dir"
      chmod 700 "$dir"
      tar -C "$work" -czf "$dir/headscale-$stamp.tar.gz" headscale
      ln -sfn "headscale-$stamp.tar.gz" "$dir/latest.tar.gz"
      ls -1t "$dir"/headscale-*.tar.gz | tail -n +31 | xargs -r rm -f
      echo "wrote $dir/headscale-$stamp.tar.gz ($(stat -c %s "$dir/headscale-$stamp.tar.gz") bytes)"
    '';
  };
  systemd.timers.headscale-backup.timerConfig = {
    RandomizedDelaySec = "10min";
    Persistent = true;
  };

  ### Using it ###############################################################
  #
  # On the box:  headscale users create <name>
  #              headscale preauthkeys create --user <id> --reusable
  # Client:      tailscale up --login-server https://hs.realo.ca --authkey <key>
}
