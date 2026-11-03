# Builds Ika's own Mesa from the release in release.env, the one the ROM's
# guest drivers are built from, with the patches in series: Lavapipe for the
# host package, and on x86_64 Mesa's Dozen Vulkan driver, which tools/ika turns
# on when it finds WSL's /dev/dxg and a Dozen GPU, and Mesa's D3D12 OpenGL
# driver with EGL for the console and app windows on WSL2 (see GRAPHICS.md,
# "WSL2"). The host's GPU drivers stay the distribution's.
#
# One patched source tree gives two meson builds. "vulkan" has Lavapipe and,
# on x86_64, Dozen, with LLVM linked statically, which only Lavapipe uses, so
# the package has no LLVM runtime dependency and a distribution's LLVM soname
# moving on cannot break it; Mesa's Vulkan version script keeps LLVM's symbols
# private to the driver. Arch has no static LLVM, so there it is LLVM 19's
# shared library (SHARED_LLVM), from a package that keeps its soname. Of the
# window systems it has only X11, for the VK_KHR_xcb_surface gfxstream's
# swapchain asks for on WSL2. "gl", x86_64 only,
# has the d3d12 Gallium driver and EGL for libglvnd, without LLVM, with Wayland
# and X11; libEGL_mesa finds libgallium beside itself ($ORIGIN). With
# DirectX-Headers older than Mesa wants (Debian 13's), meson fetches the
# version it pins.
include release.env

CVD_DIR ?= /usr/lib/cuttlefish-common
WSL_LIBDIR ?= $(CVD_DIR)/wsl
BUILD ?= build
# Keeps the Mesa release tarball between builds.
DOWNLOADS ?= $(BUILD)/downloads
# The llvm-config of the LLVM Lavapipe links, when not the one meson finds
# first.
LLVM_CONFIG ?=
# Set to link that LLVM's shared library instead, where the distribution has
# no static LLVM (Arch).
SHARED_LLVM ?=

MESA_URL = https://archive.mesa3d.org/mesa-$(MESA_VERSION).tar.xz
TARBALL = $(DOWNLOADS)/mesa-$(MESA_VERSION).tar.xz
SRC = $(BUILD)/mesa-$(MESA_VERSION)
PATCHED = $(SRC)/.ika-patched
PATCHES = $(shell sed '/^\#/d;/^$$/d' series)

VULKAN_BUILD = $(BUILD)/vulkan
VULKAN = $(VULKAN_BUILD)/.ika-built
LAVAPIPE = $(VULKAN_BUILD)/src/gallium/targets/lavapipe/libvulkan_lvp.so
LAVAPIPE_ICD = $(BUILD)/vk_lavapipe_icd.json
DOZEN_BUILD = $(VULKAN_BUILD)/src/microsoft/vulkan
GL_BUILD = $(BUILD)/gl
GL = $(GL_BUILD)/.ika-built
EGL_VENDOR = $(BUILD)/egl_vendor_ika_d3d12.json

# Dozen and D3D12 OpenGL are built for x86_64 only until Ika is tried on
# Windows on Arm.
ifneq ($(findstring x86_64,$(shell $(CC) -dumpmachine)),)
WITH_WSL = 1
endif

# Options both builds share: no tools, tests, codecs, profilers or optional
# libraries the drivers do without.
MESON_COMMON = \
	--buildtype=release \
	-Db_ndebug=true \
	-Dgles1=disabled \
	-Dglx=disabled \
	-Dvalgrind=disabled \
	-Dlibunwind=disabled \
	-Dlmsensors=disabled \
	-Dxmlconfig=disabled \
	-Dtools= \
	-Dvideo-codecs= \
	-Dspirv-to-dxil=false \
	-Dmicrosoft-clc=disabled \
	-Dbuild-tests=false \
	-Dperfetto=false

# Dozen's ICD manifest carries its absolute install path, WSL_LIBDIR/dozen.
MESON_VULKAN = \
	--prefix=$(WSL_LIBDIR) \
	--libdir=dozen \
	-Dvulkan-drivers=swrast$(if $(WITH_WSL),$(comma)microsoft-experimental) \
	-Dgallium-drivers= \
	-Dplatforms=x11 \
	-Dopengl=false \
	-Dgles2=disabled \
	-Degl=disabled \
	-Dgbm=disabled \
	-Dglvnd=disabled \
	-Dllvm=enabled \
	-Dshared-llvm=$(if $(SHARED_LLVM),enabled,disabled) \
	-Dzstd=disabled \
	-Ddisplay-info=disabled \
	-Dexpat=disabled \
	-Dvulkan-layers=

MESON_GL = \
	'-Dc_link_args=-Wl,-rpath,$$ORIGIN' \
	'-Dcpp_link_args=-Wl,-rpath,$$ORIGIN' \
	-Dgallium-drivers=d3d12 \
	-Dvulkan-drivers= \
	-Dplatforms=wayland,x11 \
	-Dopengl=true \
	-Dgles2=enabled \
	-Degl=enabled \
	-Dgbm=enabled \
	-Dglvnd=enabled \
	-Dllvm=disabled \
	-Dgallium-va=disabled

comma = ,

all: $(VULKAN) $(LAVAPIPE_ICD) $(if $(WITH_WSL),$(GL) $(EGL_VENDOR))

# The tarball is fetched here rather than by a rule of its own, so that
# install, run with another DOWNLOADS, does not fetch it again.
$(PATCHED): release.env series $(PATCHES)
	if ! echo "$(MESA_SHA256)  $(TARBALL)" | sha256sum --check --status 2>/dev/null; then \
	  mkdir -p $(DOWNLOADS) && \
	  wget --tries=3 -O $(TARBALL).part $(MESA_URL) && \
	  echo "$(MESA_SHA256)  $(TARBALL).part" | sha256sum --check --quiet && \
	  mv $(TARBALL).part $(TARBALL); \
	fi
	rm -rf $(SRC)
	mkdir -p $(BUILD)
	tar -xf $(TARBALL) -C $(BUILD)
	for patch in $(PATCHES); do patch -d $(SRC) -p1 --forward --quiet < $$patch || exit 1; done
	touch $@

$(VULKAN): $(PATCHED) Makefile
	rm -rf $(VULKAN_BUILD)
	$(if $(LLVM_CONFIG),printf "[binaries]\nllvm-config = '%s'\n" "$$(command -v $(LLVM_CONFIG))" > $(BUILD)/llvm.ini)
	meson setup $(SRC) $(VULKAN_BUILD) $(MESON_COMMON) $(MESON_VULKAN) \
		$(if $(LLVM_CONFIG),--native-file $(BUILD)/llvm.ini)
	meson compile -C $(VULKAN_BUILD)
	touch $@

$(GL): $(PATCHED) Makefile
	rm -rf $(GL_BUILD)
	meson setup $(SRC) $(GL_BUILD) $(MESON_COMMON) $(MESON_GL)
	meson compile -C $(GL_BUILD)
	touch $@

# Mesa's manifest with the Vulkan version this Lavapipe offers, pointing at
# the library beside it.
$(LAVAPIPE_ICD): $(VULKAN)
	python3 -c 'import json, sys; icd = json.load(open(sys.argv[1])); icd["ICD"]["library_path"] = "./libvk_lavapipe.so"; json.dump(icd, open(sys.argv[2], "w"), indent=4)' \
		$(wildcard $(VULKAN_BUILD)/src/gallium/targets/lavapipe/lvp_icd.*.json) $@

$(EGL_VENDOR): egl_vendor_ika_d3d12.json.in
	mkdir -p $(@D)
	sed 's|@LIBDIR@|$(WSL_LIBDIR)|' $< > $@

# Stripped here, as the rpm spec turns off its strip passes.
install: all
	install -Dspm0755 $(LAVAPIPE) $(DESTDIR)$(CVD_DIR)/bin/libvk_lavapipe.so
	install -Dpm0644 $(LAVAPIPE_ICD) $(DESTDIR)$(CVD_DIR)/bin/vk_lavapipe_icd.json
	install -d $(DESTDIR)$(CVD_DIR)/lib64
	ln -sfn ../bin/libvk_lavapipe.so $(DESTDIR)$(CVD_DIR)/lib64/vulkan.lvp.so
ifdef WITH_WSL
	install -Dspm0755 $(DOZEN_BUILD)/libvulkan_dzn.so $(DESTDIR)$(WSL_LIBDIR)/dozen/libvulkan_dzn.so
	install -Dpm0644 $(DOZEN_BUILD)/dzn_icd.*.json $(DESTDIR)$(WSL_LIBDIR)/dozen/dzn_icd.json
	install -Dspm0755 $(GL_BUILD)/src/egl/libEGL_mesa.so.0 $(DESTDIR)$(WSL_LIBDIR)/mesa-gl/libEGL_mesa.so.0
	install -Dspm0755 $(GL_BUILD)/src/gallium/targets/dri/libgallium-*.so -t $(DESTDIR)$(WSL_LIBDIR)/mesa-gl
	install -Dpm0644 $(EGL_VENDOR) $(DESTDIR)$(WSL_LIBDIR)/mesa-gl/egl_vendor.json
endif

clean:
	rm -rf $(BUILD)

.PHONY: all install clean
