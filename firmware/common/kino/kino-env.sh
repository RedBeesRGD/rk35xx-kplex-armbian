# kplex: environment for every login shell
# Toolkits that can do both use native Wayland first; Xwayland is only the fallback.
export SDL_VIDEODRIVER=wayland,x11      # SDL2
export SDL_VIDEO_DRIVER=wayland,x11     # SDL3
export GDK_BACKEND=wayland,x11
export QT_QPA_PLATFORM='wayland;xcb'
# Game controller mappings for SDL
export SDL_GAMECONTROLLERCONFIG_FILE=/etc/gamecontrollerdb.txt
