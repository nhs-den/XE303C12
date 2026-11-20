# XE303OS - lingkungan shell (di-load /etc/profile.d)
export XDG_SESSION_TYPE=x11
# Qt/GLX tanpa driver GL untuk Mali-T604: paksa jalur software supaya
# aplikasi tidak crash saat coba init OpenGL.
export QT_OPENGL=software
export QT_QUICK_BACKEND=software
export LIBGL_ALWAYS_SOFTWARE=1

if [ "$(id -u)" != "0" ] && [ -f /etc/xe303os/motd ] && [ -t 1 ]; then
    cat /etc/xe303os/motd
fi
