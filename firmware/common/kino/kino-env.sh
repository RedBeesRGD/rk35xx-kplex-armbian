# kplex: environment for every login shell
# Toolkits that can do both use native Wayland first; Xwayland is only the fallback.
export SDL_VIDEODRIVER=wayland,x11      # SDL2
export SDL_VIDEO_DRIVER=wayland,x11     # SDL3
# SDL2 hangs creating its window through libdecor under kage; kage decorates nothing anyway
export SDL_VIDEO_WAYLAND_ALLOW_LIBDECOR=0
export GDK_BACKEND=wayland,x11
export QT_QPA_PLATFORM='wayland;xcb'
# Game controller mappings for SDL
export SDL_GAMECONTROLLERCONFIG_FILE=/etc/gamecontrollerdb.txt
