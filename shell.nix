# Build environment: `nix-shell native_probe/shell.nix --run 'bash native_probe/run.sh'`
{ pkgs ? import <nixpkgs> {} }:
let
  # gpu/shadps4/video_core/renderer_vulkan/vk_instance.h asks for
  # vk::DriverId::eMesaKosmickrisp (Mesa 26.0's Vulkan-to-Metal driver, driver id 28). The
  # Vulkan the nixpkgs of the moment carries (1.4.328) predates that enum, and 1.4.328's id 26 is
  # eMesaHoneykrisp, a different Apple driver, so it cannot stand in for it. Use the Vulkan the
  # Windows build pins for the same reason (packaging/windows/deps.lock, "Vulkan 1.4.363").
  # nixpkgs keeps the loader and the headers in lockstep (vulkan-loader's meta.broken), so both
  # move together: the loader ships the only vulkan.pc, and its includedir is the headers it was
  # built with, which is what CMake's FindVulkan takes Vulkan_INCLUDE_DIR from.
  version = "1.4.363.0";
  headerSrc = pkgs.fetchFromGitHub {
    owner = "KhronosGroup";
    repo = "Vulkan-Headers";
    rev = "6802bb4733b63ed5efd3adb308a6c885ef180ea1";
    hash = "sha256-E/SBlMW1oUeUT0MtWzQp0k+OSZLc9ho7g+1oTd7z7+Y=";
  };
  loaderSrc = pkgs.fetchFromGitHub {
    owner = "KhronosGroup";
    repo = "Vulkan-Loader";
    rev = "vulkan-sdk-${version}";
    hash = "sha256-hm+e1rynOMa9uBGSzmxaYgzR32ZhWV9VC2q961UoCKo=";
  };
  vulkan-headers = pkgs.vulkan-headers.overrideAttrs (old: {
    inherit version;
    src = headerSrc;
  });
  vulkan-loader = (pkgs.vulkan-loader.override { inherit vulkan-headers; }).overrideAttrs (old: {
    inherit version;
    src = loaderSrc;
    # meta.broken is loader.version != vulkan-headers.version, evaluated before the version
    # above was replaced: the two do match now (its fix-pkgconfig.patch still applies).
    meta = old.meta // { broken = false; };
  });
in
pkgs.mkShell {
  packages = with pkgs; [
    gcc gnumake cmake ninja pkg-config python3 binutils git
    vulkan-headers vulkan-loader sdl3
    # GPU library (gpu/): shadPS4 video core dependencies
    # nixpkgs 25.11 renamed this package to `xxHash`; keep the old name working too.
    boost fmt magic-enum robin-map (pkgs.xxHash or pkgs.xxhash) vulkan-memory-allocator glslang spirv-cross xbyak zydis spirv-headers miniz libx11 libxcb xorgproto wayland
  ];
  # Off NixOS vkCreateInstance fails with VK_ERROR_INCOMPATIBLE_DRIVER: the loader searches
  # /run/opengl-driver/share (NixOS's drivers) and XDG_DATA_DIRS, so it finds the distribution's
  # ICD manifests but cannot load the drivers they name -- those need the host's libLLVM-15.so.1,
  # libz.so.1 and so on, which this environment's dynamic loader does not search for (adding the
  # host library directory to LD_LIBRARY_PATH is not an option: its older libc and libstdc++
  # shadow the ones the binaries are built against here). Name the ICDs nixpkgs builds instead;
  # they load with the rest of the environment. NixOS keeps its own.
  shellHook = ''
    if [[ -z ''${VK_DRIVER_FILES:-} && ! -d /run/opengl-driver/share/vulkan/icd.d ]]; then
      export VK_DRIVER_FILES=$(ls ${pkgs.mesa}/share/vulkan/icd.d/*.json 2>/dev/null | tr '\n' ':' | sed 's/:$//')
    fi
  '';
}
