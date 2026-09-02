# Headscale: self-hosted Tailscale coordination server.
#
# Everything that is specific to this machine's role lives here; server.nix
# stays a generic minimal Vultr box.
#
# Status: software and service are in place, but there is no domain name and
# no TLS certificate yet. Until then headscale listens on 127.0.0.1:8080 only
# (the module default) and the two placeholders below must be filled in
# before any client can connect. See "Finishing the setup" at the bottom.
{ config, lib, pkgs, ... }:

let
  # PLACEHOLDERS: replace when the DNS name exists.
  # Public name clients connect to (https://<fqdn>).
  fqdn = "headscale.example.com";
  # MagicDNS suffix for nodes (<node>.<baseDomain>). Must not be the same as,
  # or a parent of, the server's own domain.
  baseDomain = "ts.example.com";
in
{
  networking.hostName = "headscale";

  services.headscale = {
    enable = true;
    # Loopback only until TLS is set up (see below). Then switch to
    #   address = "0.0.0.0"; port = 443;
    address = "127.0.0.1";
    port = 8080;

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

      ### TLS: pick one of the two when the certificate question is settled.
      # (a) Let headscale get its own Let's Encrypt certificate. Needs the
      #     public listener on 443 and port 80 reachable for HTTP-01:
      # tls_letsencrypt_hostname = fqdn;
      # tls_letsencrypt_challenge_type = "HTTP-01";
      # tls_letsencrypt_listen = ":http";
      #
      # (b) Bring your own certificate (readable by the headscale user):
      # tls_cert_path = "/var/lib/headscale/tls/fullchain.pem";
      # tls_key_path = "/var/lib/headscale/tls/privkey.pem";
    };
  };

  # 80 for the ACME HTTP-01 challenge, 443 for clients. Nothing listens on
  # them yet; they are open so that only the TLS block above changes later.
  networking.firewall.allowedTCPPorts = [ 80 443 ];

  # Let realo run `headscale users create …` etc. without sudo: the CLI talks
  # to the unix socket in /run/headscale, which is group-readable.
  users.users.realo.extraGroups = [ "headscale" ];

  ### Finishing the setup ####################################################
  #
  # 1. Point <fqdn> at 104.238.132.193, set `fqdn` and `baseDomain` above.
  # 2. Enable one TLS block, set address = "0.0.0.0" and port = 443.
  # 3. Deploy: SERVER=root@104.238.132.193 ./build.sh deploy
  # 4. On the box:  headscale users create <name>
  #                 headscale preauthkeys create --user <id> --reusable
  #    Client:      tailscale up --login-server https://<fqdn> --authkey <key>
}
