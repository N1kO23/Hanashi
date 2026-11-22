#include "my_application.h"

int main(int argc, char** argv) {
  // Where no sound server answers, libmpv plays sound through SDL, and SDL
  // then takes SIGTERM and SIGINT for a quit event nobody reads: the app
  // would outlive a logout or a shutdown. Unless set otherwise, SDL leaves
  // signals alone.
  g_setenv("SDL_NO_SIGNAL_HANDLERS", "1", FALSE);
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
