# realo.ca: a plain web server.
#
# Everything specific to this machine's role lives here; server.nix stays the
# generic minimal Vultr box. The web server itself is not decided yet, so this
# is the smallest useful thing: nginx serving a static directory over HTTPS,
# with a Let's Encrypt certificate for realo.ca. Swap nginx for something else
# by replacing the `services.nginx` block; the ACME part is independent of it
# as long as whatever listens on :80 serves /.well-known/acme-challenge/ from
# the directory the acme module writes to (see security.acme.certs.*.webroot).
#
# Public name: realo.ca (A record at Dyn). Let's Encrypt allows 5 failed
# validations per hostname per hour: the A record must point at this box
# before the certificate can be issued. Until then nginx runs with a
# self-signed placeholder and `acme-realo.ca.service` fails; once DNS is
# right, `systemctl start acme-realo.ca` (or wait for its daily timer).
{ config, lib, pkgs, ... }:

let
  fqdn = "realo.ca";
  # What is served until real content is put in /var/www/${fqdn}.
  placeholder = pkgs.writeTextDir "index.html" ''
    <!doctype html>
    <title>${fqdn}</title>
    <h1>${fqdn}</h1>
    <p>Nothing here yet.</p>
  '';
in
{
  networking.hostName = "realo-ca";

  security.acme = {
    acceptTerms = true;
    defaults.email = "real@realo.ca";
  };

  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedGzipSettings = true;
    recommendedProxySettings = true;
    recommendedOptimisation = true;

    virtualHosts.${fqdn} = {
      # enableACME registers security.acme.certs."realo.ca" with nginx's
      # webroot and reloads nginx when the certificate changes.
      enableACME = true;
      forceSSL = true;
      root = "/var/www/${fqdn}";
    };
  };

  # Create the document root once, with the placeholder page; never
  # overwritten afterwards (tmpfiles `C` copies only if the target is absent).
  systemd.tmpfiles.rules = [
    "d /var/www 0755 root root -"
    "C /var/www/${fqdn} 0755 root root - ${placeholder}"
  ];

  # 80 for the ACME HTTP-01 challenge and the redirect, 443 for the site.
  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
