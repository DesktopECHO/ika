# Builds Ika's WSL2 GPU helpers: the VK_LAYER_IKA_dzn_fix Vulkan layer and the
# libd3d12.so shim. tools/ika turns both on when it finds WSL's /dev/dxg and
# Mesa Dozen; see GRAPHICS.md, "WSL2".
CFLAGS ?= -O2 -g
CFLAGS += -Wall -Wextra
LIBDIR ?= /usr/lib/cuttlefish-common/wsl
LAYERDIR ?= /usr/share/vulkan/implicit_layer.d
BUILD ?= build

LAYER = $(BUILD)/libVkLayer_ika_dzn_fix.so
SHIM = $(BUILD)/d3d12/libd3d12.so
MANIFEST = $(BUILD)/VK_LAYER_IKA_dzn_fix.json

all: $(LAYER) $(SHIM) $(MANIFEST)

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

install: all
	install -Dpm0644 $(LAYER) $(DESTDIR)$(LIBDIR)/libVkLayer_ika_dzn_fix.so
	install -Dpm0644 $(SHIM) $(DESTDIR)$(LIBDIR)/d3d12/libd3d12.so
	install -Dpm0644 $(MANIFEST) $(DESTDIR)$(LAYERDIR)/VK_LAYER_IKA_dzn_fix.json

clean:
	rm -rf $(BUILD)

.PHONY: all install clean
