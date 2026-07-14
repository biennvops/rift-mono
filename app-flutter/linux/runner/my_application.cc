#include "my_application.h"

#include <string>

#include <flutter_linux/flutter_linux.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr char kDesktopClipboardChannel[] = "rift/desktop/clipboard";
std::string g_last_logged_clipboard_fingerprint;

std::string fingerprint_clipboard_payload(const char* content_type,
                                          const uint8_t* bytes,
                                          size_t bytes_length) {
  if (content_type == nullptr || bytes == nullptr) {
    return std::string();
  }

  g_autofree gchar* checksum = g_compute_checksum_for_data(
      G_CHECKSUM_SHA256,
      bytes,
      bytes_length);
  if (checksum == nullptr) {
    return std::string();
  }

  return std::string(content_type) + ":" + std::to_string(bytes_length) + ":" +
         checksum;
}

void log_clipboard_read_if_changed(const char* content_type,
                                   const uint8_t* bytes,
                                   size_t bytes_length) {
  const std::string fingerprint =
      fingerprint_clipboard_payload(content_type, bytes, bytes_length);
  if (fingerprint.empty() || fingerprint == g_last_logged_clipboard_fingerprint) {
    return;
  }

  g_last_logged_clipboard_fingerprint = fingerprint;
  g_message("Rift clipboard bridge: read %s payload (%zu bytes).",
            content_type,
            bytes_length);
}

void log_empty_clipboard_if_changed() {
  constexpr char kEmptyFingerprint[] = "empty";
  if (g_last_logged_clipboard_fingerprint == kEmptyFingerprint) {
    return;
  }

  g_last_logged_clipboard_fingerprint = kEmptyFingerprint;
  g_message("Rift clipboard bridge: no supported clipboard payload available.");
}

struct ClipboardReadRequest {
  FlMethodCall* method_call;
};

FlMethodResponse* build_clipboard_response(const char* content_type,
                                           const uint8_t* bytes,
                                           size_t bytes_length) {
  g_autoptr(FlValue) response = fl_value_new_map();
  fl_value_set_string_take(
      response, "contentType", fl_value_new_string(content_type));
  fl_value_set_string_take(
      response,
      "bytes",
      fl_value_new_uint8_list(bytes, bytes_length));
  return FL_METHOD_RESPONSE(fl_method_success_response_new(response));
}

void respond_to_clipboard_request(ClipboardReadRequest* request,
                                  FlMethodResponse* response) {
  fl_method_call_respond(request->method_call, response, nullptr);
  g_object_unref(request->method_call);
  g_free(request);
}

void clipboard_text_requested_cb(GtkClipboard* clipboard,
                                 const gchar* text,
                                 gpointer user_data) {
  auto* request = static_cast<ClipboardReadRequest*>(user_data);
  if (text != nullptr) {
    const auto* bytes = reinterpret_cast<const uint8_t*>(text);
    const auto bytes_length = strlen(text);
    log_clipboard_read_if_changed("text/plain", bytes, bytes_length);
    g_autoptr(FlMethodResponse) response =
        build_clipboard_response("text/plain", bytes, bytes_length);
    respond_to_clipboard_request(request, response);
    return;
  }

  log_empty_clipboard_if_changed();
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  respond_to_clipboard_request(request, response);
}

void clipboard_image_requested_cb(GtkClipboard* clipboard,
                                  GdkPixbuf* image,
                                  gpointer user_data) {
  auto* request = static_cast<ClipboardReadRequest*>(user_data);
  if (image != nullptr) {
    gchar* buffer = nullptr;
    gsize buffer_size = 0;
    g_autoptr(GError) error = nullptr;
    if (gdk_pixbuf_save_to_buffer(
            image,
            &buffer,
            &buffer_size,
            "png",
            &error,
            nullptr)) {
      log_clipboard_read_if_changed(
          "image/png",
          reinterpret_cast<const uint8_t*>(buffer),
          buffer_size);
      g_autoptr(FlMethodResponse) response = build_clipboard_response(
          "image/png",
          reinterpret_cast<const uint8_t*>(buffer),
          buffer_size);
      g_free(buffer);
      respond_to_clipboard_request(request, response);
      return;
    }
    if (error != nullptr) {
      g_warning("Rift clipboard bridge: failed to encode PNG clipboard image: %s",
                error->message);
    }
  }

  gtk_clipboard_request_text(clipboard, clipboard_text_requested_cb, request);
}

bool begin_async_get_clipboard_content(FlMethodCall* method_call) {
  GtkClipboard* clipboard = gtk_clipboard_get_default(gdk_display_get_default());
  if (clipboard == nullptr) {
    g_message("Rift clipboard bridge: GTK clipboard was unavailable.");
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    fl_method_call_respond(method_call, response, nullptr);
    return true;
  }

  auto* request = g_new0(ClipboardReadRequest, 1);
  request->method_call = FL_METHOD_CALL(g_object_ref(method_call));
  gtk_clipboard_request_image(clipboard, clipboard_image_requested_cb, request);
  return true;
}

FlMethodResponse* set_clipboard_content(FlValue* args) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_args", "contentType and bytes are required.", nullptr));
  }

  FlValue* content_type_value = fl_value_lookup_string(args, "contentType");
  FlValue* bytes_value = fl_value_lookup_string(args, "bytes");
  if (content_type_value == nullptr || bytes_value == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_args", "contentType and bytes are required.", nullptr));
  }

  const gchar* content_type = fl_value_get_string(content_type_value);
  if (content_type == nullptr ||
      fl_value_get_type(bytes_value) != FL_VALUE_TYPE_UINT8_LIST) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_args", "Invalid clipboard payload.", nullptr));
  }

  size_t bytes_length = fl_value_get_length(bytes_value);
  const uint8_t* bytes = fl_value_get_uint8_list(bytes_value);
  GtkClipboard* clipboard = gtk_clipboard_get_default(gdk_display_get_default());
  if (clipboard == nullptr) {
    g_warning("Rift clipboard bridge: GTK clipboard was unavailable for write.");
    return FL_METHOD_RESPONSE(fl_method_success_response_new(
        fl_value_new_bool(false)));
  }

  gboolean applied = FALSE;
  if (g_strcmp0(content_type, "text/plain") == 0 ||
      g_strcmp0(content_type, "clipboard") == 0) {
    gchar* text = g_strndup(reinterpret_cast<const gchar*>(bytes), bytes_length);
    gtk_clipboard_set_text(clipboard, text, bytes_length);
    gtk_clipboard_store(clipboard);
    g_free(text);
    applied = TRUE;
    g_message("Rift clipboard bridge: wrote text/plain payload (%zu bytes).",
              bytes_length);
  } else if (g_strcmp0(content_type, "image/png") == 0) {
    g_autoptr(GInputStream) stream = g_memory_input_stream_new_from_data(
        bytes, bytes_length, nullptr);
    g_autoptr(GError) error = nullptr;
    g_autoptr(GdkPixbuf) pixbuf =
        gdk_pixbuf_new_from_stream(stream, nullptr, &error);
    if (pixbuf != nullptr) {
      gtk_clipboard_set_image(clipboard, pixbuf);
      gtk_clipboard_store(clipboard);
      applied = TRUE;
      g_message("Rift clipboard bridge: wrote image/png payload (%zu bytes).",
                bytes_length);
    } else if (error != nullptr) {
      g_warning("Rift clipboard bridge: failed to decode PNG clipboard payload: %s",
                error->message);
    }
  } else {
    g_message("Rift clipboard bridge: unsupported write content type %s.",
              content_type);
  }

  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(applied)));
}

void clipboard_method_call_cb(FlMethodChannel* channel,
                              FlMethodCall* method_call,
                              gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (strcmp(method, "getClipboardContent") == 0) {
    begin_async_get_clipboard_content(method_call);
    return;
  } else if (strcmp(method, "setClipboardContent") == 0) {
    response = set_clipboard_content(fl_method_call_get_args(method_call));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

void register_desktop_clipboard_channel(FlView* view) {
  FlEngine* engine = fl_view_get_engine(view);
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(engine);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      messenger,
      kDesktopClipboardChannel,
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      channel,
      clipboard_method_call_cb,
      nullptr,
      nullptr);
  g_object_set_data_full(
      G_OBJECT(view),
      "rift-desktop-clipboard-channel",
      g_object_ref(channel),
      g_object_unref);
}

}  // namespace

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "app_flutter");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "app_flutter");
  }

  gtk_window_set_default_size(window, 1280, 720);

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
  register_desktop_clipboard_channel(view);

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

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
