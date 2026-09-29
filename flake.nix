{
  description = "Fork pessoal do elementary Code";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      packageFor = system:
        let
          pkgs = import nixpkgs { inherit system; };
          runtimeInputs = [ pkgs.universal-ctags ];
        in
        pkgs.stdenv.mkDerivation {
          pname = "io.elementary.code";
          version = "8.4.0";
          src = self;

          nativeBuildInputs = with pkgs; [
            gettext
            gobject-introspection
            meson
            ninja
            pkg-config
            vala
            wrapGAppsHook3
            makeWrapper
          ];

          buildInputs = with pkgs; [
            glib
            libgee
            gtk3
            pantheon.granite
            libhandy
            gtksourceview4
            libpeas2
            libgit2-glib
            fontconfig
            pango
            vte
            sqlite
            editorconfig-core-c
            gtkspell3
            libsoup_3
          ];

          mesonFlags = [
            "-Dhave_pkexec=false"
            "-Ddevelopment=false"
          ];

          preFixup = ''
            gappsWrapperArgs+=(
              --prefix PATH : "${pkgs.lib.makeBinPath runtimeInputs}"
            )
          '';

          meta = with pkgs.lib; {
            description = "Editor de código do elementary OS, em um fork pessoal";
            homepage = "https://github.com/elementary/code";
            license = licenses.gpl3Plus;
            mainProgram = "io.elementary.code";
            platforms = [ "x86_64-linux" "aarch64-linux" ];
          };
        };
    in
    {
      packages = forAllSystems (system: {
        default = packageFor system;
        io-elementary-code = packageFor system;
      });

      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          app = packageFor system;
        in
        {
          default = pkgs.mkShell {
            inputsFrom = [ app ];
            packages = with pkgs; [ meson ninja vala gettext pkg-config ];
          };
        });
    };
}
