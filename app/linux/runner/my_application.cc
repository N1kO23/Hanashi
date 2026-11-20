#include "my_application.h"

#include <flutter_linux/flutter_linux.h>

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received. Started at login (--hidden),
// Hanashi waits in the tray: the app shows the window when the user opens it.
static void first_frame_cb(MyApplication* self, FlView* view) {
  if (self->dart_entrypoint_arguments != nullptr &&
      g_strv_contains(
          const_cast<const gchar* const*>(self->dart_entrypoint_arguments),
          "--hidden")) {
    return;
  }
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  // Launched again while running (e.g. hidden in the tray): show the window
  // instead of starting a second copy.
  GList* windows = gtk_application_get_windows(GTK_APPLICATION(application));
  if (windows != nullptr) {
    gtk_widget_show(GTK_WIDGET(windows->data));
    gtk_window_present(GTK_WINDOW(windows->data));
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Hanashi draws its own title bar and window buttons. A header bar that is
  // never shown keeps GTK's client-side decorations (resize borders and
  // shadow) without any visible native title bar.
  GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
  gtk_header_bar_set_title(header_bar, "Hanashi");
  gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  gtk_window_set_title(window, "Hanashi");

  // Window icon from the bundled assets (used on X11; Wayland desktops take
  // the icon from the installed .desktop file instead). The windows' default,
  // not this one's own, so that the app can change it to the theme's
  // (lib/desktop/window_theme.dart).
  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", nullptr);
  if (executable != nullptr) {
    g_autofree gchar* bundle_dir = g_path_get_dirname(executable);
    g_autofree gchar* icon = g_build_filename(bundle_dir, "data", "flutter_assets", "assets",
                                              "branding", "icon_default.png", nullptr);
    gtk_window_set_default_icon_from_file(icon, nullptr);
  }

  gtk_window_set_default_size(window, 1200, 780);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  // Dropped files come as file URIs only. desktop_drop 0.8 prefers the XDG
  // portal's file transfer (which KDE's file manager offers), but finishes
  // the drop before resolving it, so the source revokes the transfer and the
  // drop arrives empty. (Fixed in desktop_drop 0.9, which needs cross_file
  // 0.4; file_picker and image_picker do not support that yet.)
  GtkTargetList* drop_targets = gtk_target_list_new(nullptr, 0);
  gtk_target_list_add_uri_targets(drop_targets, 0);
  gtk_drag_dest_set_target_list(GTK_WIDGET(view), drop_targets);
  gtk_target_list_unref(drop_targets);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  // One copy at a time: two would share (and corrupt) the encryption state.
  // A second launch activates the running copy instead. Debug builds may
  // run side by side with an installed copy.
#ifdef NDEBUG
#if GLIB_CHECK_VERSION(2, 74, 0)
  const GApplicationFlags flags = G_APPLICATION_DEFAULT_FLAGS;
#else
  const GApplicationFlags flags = G_APPLICATION_FLAGS_NONE;
#endif
#else
  const GApplicationFlags flags = G_APPLICATION_NON_UNIQUE;
#endif
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     flags, nullptr));
}
