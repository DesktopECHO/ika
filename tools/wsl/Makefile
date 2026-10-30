# Builds Ika's WSL2 helpers: the VK_LAYER_IKA_dzn_fix Vulkan layer, the
# libd3d12.so shim and, on x86_64, Mesa's Dozen driver (mesa/build-dozen.sh),
# which tools/ika turns on when it finds WSL's /dev/dxg and a Dozen GPU (see
# GRAPHICS.md, "WSL2"), and Mesa's D3D12 OpenGL driver with EGL for the console
# and app windows (mesa/build-d3d12-gl.sh); and libdecor's GTK plugin for
# Ika's windows on WSLg (libdecor/build-libdecor-gtk.sh).
CFLAGS ?= -O2 -g
CFLAGS += -Wall -Wextra
LIBDIR ?= /usr/lib/cuttlefish-common/wsl
LAYERDIR ?= /usr/share/vulkan/implicit_layer.d
BUILD ?= build
# Keeps the Mesa and libdecor release tarballs between builds.
DOWNLOADS ?= $(BUILD)/downloads

LAYER = $(BUILD)/libVkLayer_ika_dzn_fix.so
SHIM = $(BUILD)/d3d12/libd3d12.so
MANIFEST = $(BUILD)/VK_LAYER_IKA_dzn_fix.json
DOZEN_BUILD = $(BUILD)/dozen/build/src/microsoft/vulkan
DOZEN = $(DOZEN_BUILD)/libvulkan_dzn.so
D3D12_GL_BUILD = $(BUILD)/d3d12-gl/build
D3D12_GL = $(D3D12_GL_BUILD)/src/egl/libEGL_mesa.so.0
EGL_VENDOR = $(BUILD)/egl_vendor_ika_d3d12.json
LIBDECOR_GTK = $(BUILD)/libdecor/build/src/plugins/gtk/libdecor-gtk.so

# Dozen is built for x86_64 only until Ika is tried on Windows on Arm.
ifneq ($(findstring x86_64,$(shell $(CC) -dumpmachine)),)
WITH_DOZEN = 1
endif

all: $(LAYER) $(SHIM) $(MANIFEST) $(LIBDECOR_GTK) $(if $(WITH_DOZEN),$(DOZEN) $(D3D12_GL) $(EGL_VENDOR))

$(LAYER): ika_dzn_fix.c
	mkdir -p $(@D)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -fPIC -shared -fvisibility=hidden -o $@ $< -ldl -lpthread

# -z nodelete keeps the DRED watcher threads' code mapped after Mesa dlcloses
# libd3d12.so.
$(SHIM): d3d12_shim.c d3d12_dred.cpp
	mkdir -p $(@D)
	$(CC) $(CPPFLAGS) $(CFLAGS) -fPIC -fvisibility=hidden -c -o $(BUILD)/d3d12_shim.o d3d12_shim.c
	$(CXX) $(CPPFLAGS) $(CFLAGS) -fPIC -fvisibility=hidden -I/usr/include/wsl/stubs -c -o $(BUILD)/d3d12_dred.o d3d12_dred.cpp
	$(CXX) $(LDFLAGS) -shared -fvisibility=hidden -Wl,-z,nodelete -o $@ $(BUILD)/d3d12_shim.o $(BUILD)/d3d12_dred.o -ldl -lpthread

$(MANIFEST): VK_LAYER_IKA_dzn_fix.json.in
	mkdir -p $(@D)
	sed 's|@LIBDIR@|$(LIBDIR)|' $< > $@

$(DOZEN): mesa/build-dozen.sh mesa/series $(wildcard mesa/*.patch)
	mesa/build-dozen.sh $(BUILD)/dozen $(DOWNLOADS) $(LIBDIR)/dozen

$(D3D12_GL): mesa/build-d3d12-gl.sh mesa/series-gl $(wildcard mesa/*.patch)
	mesa/build-d3d12-gl.sh $(BUILD)/d3d12-gl $(DOWNLOADS)

$(EGL_VENDOR): egl_vendor_ika_d3d12.json.in
	mkdir -p $(@D)
	sed 's|@LIBDIR@|$(LIBDIR)|' $< > $@

$(LIBDECOR_GTK): libdecor/build-libdecor-gtk.sh libdecor/series $(wildcard libdecor/*.patch)
	libdecor/build-libdecor-gtk.sh $(BUILD)/libdecor $(DOWNLOADS)

install: all
	install -Dpm0644 $(LAYER) $(DESTDIR)$(LIBDIR)/libVkLayer_ika_dzn_fix.so
	install -Dpm0644 $(SHIM) $(DESTDIR)$(LIBDIR)/d3d12/libd3d12.so
	install -Dpm0644 $(MANIFEST) $(DESTDIR)$(LAYERDIR)/VK_LAYER_IKA_dzn_fix.json
	install -Dpm0644 $(LIBDECOR_GTK) $(DESTDIR)$(LIBDIR)/libdecor/libdecor-gtk.so
ifdef WITH_DOZEN
	install -Dpm0644 $(DOZEN) $(DESTDIR)$(LIBDIR)/dozen/libvulkan_dzn.so
	install -Dpm0644 $(DOZEN_BUILD)/dzn_icd.*.json $(DESTDIR)$(LIBDIR)/dozen/dzn_icd.json
	install -Dpm0644 $(D3D12_GL) $(DESTDIR)$(LIBDIR)/mesa-gl/libEGL_mesa.so.0
	install -Dpm0644 $(wildcard $(D3D12_GL_BUILD)/src/gallium/targets/dri/libgallium-*.so) \
		-t $(DESTDIR)$(LIBDIR)/mesa-gl
	install -Dpm0644 $(EGL_VENDOR) $(DESTDIR)$(LIBDIR)/mesa-gl/egl_vendor.json
endif

clean:
	rm -rf $(BUILD)

.PHONY: all install clean
