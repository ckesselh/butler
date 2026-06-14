{
  lib,
  stdenv,
  zig_0_16,
}:

# butler: a command-line wrapper around the BuchhaltungsButler (BHB) accounting
# API (transactions, receipts, bookings). Single static-ish Zig
# binary, no external Zig package dependencies — it uses only the standard
# library (std.http.Client for HTTPS, std.json, std.crypto for base64). Because
# there are no zig package deps, the build is fully offline: nothing is fetched
# at build time and no zon2nix vendoring is required.
stdenv.mkDerivation {
  pname = "butler";
  # Keep in sync with build.zig.zon (the authoritative copy); CI asserts the
  # two agree.
  version = "0.1.0";

  src = ./.;

  # The nixpkgs Zig derivation carries its own setupHook (see
  # pkgs/development/compilers/zig/setup-hook.sh), so adding `zig_0_16` to
  # nativeBuildInputs is all that is needed. The hook installs:
  #   - zigConfigurePhase: exports ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
  #   - zigBuildPhase:     `zig build` (+ -Dcpu=baseline --release=safe)
  #   - zigCheckPhase:     `zig build test`
  #   - zigInstallPhase:   `zig build install --prefix $out`
  nativeBuildInputs = [ zig_0_16 ];

  # build.zig defines a `test` step; let the Zig setup hook run it as the
  # check phase so `nix build` exercises the unit tests (all offline).

  meta = {
    description = "Command-line wrapper for the BuchhaltungsButler (BHB) accounting API";
    longDescription = ''
      butler is an AWS/Azure-CLI-style command-line client for the
      BuchhaltungsButler accounting API. It covers transactions, receipts and
      bookings: list/show with rich decoding, uploading and booking receipts,
      booking payments directly or as free/split bookings, settling receipts
      against payments, and open-item discovery (unbooked / unpaid / missing
      receipt). Authentication combines HTTP Basic (API client id + secret) with
      an account-level api_key sent in the JSON body; credentials are captured
      via `butler login` into $XDG_CONFIG_HOME/butler/ (default ~/.config/butler/,
      mode 0600). New postings are created confirmed but unfixed, so they stay
      reviewable and editable in the BHB web UI; `butler bookings unconfirm`
      stages one for UI-only review.
    '';
    homepage = "https://github.com/ckesselh/butler";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
    mainProgram = "butler";
  };
}
