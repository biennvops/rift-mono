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
constexpr char kLinuxNotificationsChannel[] = "rift/linux/notifications";
constexpr char kLinuxNotificationActionName[] = "notificationActivated";
constexpr char kLinuxNotificationActionOpenName[] = "notificationActionOpen";
constexpr char kLinuxNotificationActionDismissName[] =
    "notificationActionDismiss";
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

std::string encode_notification_payload(const gchar* route,
                                        const gchar* destination_path,
                                        FlValue* payload) {
  std::string encoded;
  auto append_pair = [&encoded](const std::string& key,
                                const std::string& value) {
    g_autofree gchar* escaped_key = g_uri_escape_string(key.c_str(), nullptr, TRUE);
    g_autofree gchar* escaped_value =
        g_uri_escape_string(value.c_str(), nullptr, TRUE);
    if (!encoded.empty()) {
      encoded.push_back('&');
    }
    encoded.append(escaped_key);
    encoded.push_back('=');
    encoded.append(escaped_value);
  };

  if (route != nullptr && *route != '\0') {
    append_pair("route", route);
  }
  if (destination_path != nullptr && *destination_path != '\0') {
    append_pair("destinationPath", destination_path);
  }
  if (payload != nullptr && fl_value_get_type(payload) == FL_VALUE_TYPE_MAP) {
    for (size_t i = 0; i < fl_value_get_length(payload); ++i) {
      FlValue* key_value = fl_value_get_map_key(payload, i);
      FlValue* entry_value = fl_value_get_map_value(payload, i);
      if (key_value == nullptr || entry_value == nullptr ||
          fl_value_get_type(key_value) != FL_VALUE_TYPE_STRING) {
        continue;
      }

      const gchar* key = fl_value_get_string(key_value);
      switch (fl_value_get_type(entry_value)) {
        case FL_VALUE_TYPE_STRING:
          append_pair(key, fl_value_get_string(entry_value));
          break;
        case FL_VALUE_TYPE_BOOL:
          append_pair(key, fl_value_get_bool(entry_value) ? "true" : "false");
          break;
        case FL_VALUE_TYPE_INT:
          append_pair(key, std::to_string(fl_value_get_int(entry_value)));
          break;
        case FL_VALUE_TYPE_FLOAT:
          append_pair(key, std::to_string(fl_value_get_float(entry_value)));
          break;
        default:
          break;
      }
    }
  }

  return encoded;
}

FlValue* decode_notification_payload(const gchar* encoded) {
  g_autoptr(FlValue) payload = fl_value_new_map();
  if (encoded == nullptr || *encoded == '\0') {
    return fl_value_ref(payload);
  }

  g_auto(GStrv) pairs = g_strsplit(encoded, "&", -1);
  for (gint i = 0; pairs[i] != nullptr; ++i) {
    if (pairs[i][0] == '\0') {
      continue;
    }
    g_auto(GStrv) kv = g_strsplit(pairs[i], "=", 2);
    if (kv[0] == nullptr || kv[1] == nullptr) {
      continue;
    }

    g_autofree gchar* key = g_uri_unescape_string(kv[0], nullptr);
    g_autofree gchar* value = g_uri_unescape_string(kv[1], nullptr);
    if (key == nullptr || value == nullptr) {
      continue;
    }

    if (g_strcmp0(value, "true") == 0) {
      fl_value_set_string_take(payload, key, fl_value_new_bool(TRUE));
    } else if (g_strcmp0(value, "false") == 0) {
      fl_value_set_string_take(payload, key, fl_value_new_bool(FALSE));
    } else {
      fl_value_set_string_take(payload, key, fl_value_new_string(value));
    }
  }

  return fl_value_ref(payload);
}

}  // namespace

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* linux_notifications_channel;
  gchar* pending_notification_payload;
  gboolean start_hidden;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  if (!self->start_hidden) {
    gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
  }
}

static void dispatch_linux_notification_payload(MyApplication* self,
                                                const gchar* encoded_payload) {
  if (self->linux_notifications_channel == nullptr) {
    g_free(self->pending_notification_payload);
    self->pending_notification_payload = g_strdup(encoded_payload);
    return;
  }

  g_autoptr(FlValue) payload = decode_notification_payload(encoded_payload);
  fl_method_channel_invoke_method(
      self->linux_notifications_channel,
      "notificationActivated",
      payload,
      nullptr,
      nullptr,
      nullptr);
}

static void notification_activated_action(GSimpleAction* action,
                                          GVariant* parameter,
                                          gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  const gchar* encoded_payload =
      parameter == nullptr ? "" : g_variant_get_string(parameter, nullptr);
  dispatch_linux_notification_payload(self, encoded_payload);
  g_application_activate(G_APPLICATION(self));
}

static void notification_button_action(GSimpleAction* action,
                                       GVariant* parameter,
                                       gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  const gchar* encoded_payload =
      parameter == nullptr ? "" : g_variant_get_string(parameter, nullptr);
  dispatch_linux_notification_payload(self, encoded_payload);
}

static std::string add_notification_action_to_payload(
    const std::string& encoded_payload,
    const char* action_name) {
  std::string action_payload = encoded_payload;
  g_autofree gchar* escaped_key =
      g_uri_escape_string("notificationAction", nullptr, TRUE);
  g_autofree gchar* escaped_value =
      g_uri_escape_string(action_name, nullptr, TRUE);
  if (!action_payload.empty()) {
    action_payload.push_back('&');
  }
  action_payload.append(escaped_key);
  action_payload.push_back('=');
  action_payload.append(escaped_value);
  return action_payload;
}

static FlMethodResponse* show_linux_notification(MyApplication* self,
                                                 FlValue* args) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_args", "title, body, and route are required.", nullptr));
  }

  FlValue* title_value = fl_value_lookup_string(args, "title");
  FlValue* body_value = fl_value_lookup_string(args, "body");
  FlValue* route_value = fl_value_lookup_string(args, "route");
  FlValue* destination_path_value =
      fl_value_lookup_string(args, "destinationPath");
  FlValue* payload_value = fl_value_lookup_string(args, "payload");
  FlValue* actions_value = fl_value_lookup_string(args, "actions");
  if (title_value == nullptr || body_value == nullptr || route_value == nullptr ||
      fl_value_get_type(title_value) != FL_VALUE_TYPE_STRING ||
      fl_value_get_type(body_value) != FL_VALUE_TYPE_STRING ||
      fl_value_get_type(route_value) != FL_VALUE_TYPE_STRING) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_args", "title, body, and route are required.", nullptr));
  }

  const gchar* title = fl_value_get_string(title_value);
  const gchar* body = fl_value_get_string(body_value);
  const gchar* route = fl_value_get_string(route_value);
  const gchar* destination_path =
      destination_path_value != nullptr &&
              fl_value_get_type(destination_path_value) == FL_VALUE_TYPE_STRING
          ? fl_value_get_string(destination_path_value)
          : nullptr;

  std::string encoded_payload =
      encode_notification_payload(route, destination_path, payload_value);

  g_autoptr(GNotification) notification = g_notification_new(title);
  g_notification_set_body(notification, body);
  g_notification_set_default_action_and_target_value(
      notification,
      "app.notificationActivated",
      g_variant_new_string(encoded_payload.c_str()));
  if (actions_value != nullptr &&
      fl_value_get_type(actions_value) == FL_VALUE_TYPE_LIST) {
    for (size_t i = 0; i < fl_value_get_length(actions_value); ++i) {
      FlValue* action_value = fl_value_get_list_value(actions_value, i);
      if (action_value == nullptr ||
          fl_value_get_type(action_value) != FL_VALUE_TYPE_MAP) {
        continue;
      }

      FlValue* action_id_value = fl_value_lookup_string(action_value, "id");
      FlValue* action_title_value =
          fl_value_lookup_string(action_value, "title");
      if (action_id_value == nullptr || action_title_value == nullptr ||
          fl_value_get_type(action_id_value) != FL_VALUE_TYPE_STRING ||
          fl_value_get_type(action_title_value) != FL_VALUE_TYPE_STRING) {
        continue;
      }

      const gchar* action_id = fl_value_get_string(action_id_value);
      const gchar* action_title = fl_value_get_string(action_title_value);
      const gchar* detailed_action = nullptr;
      if (g_strcmp0(action_id, "open") == 0) {
        detailed_action = "app.notificationActionOpen";
      } else if (g_strcmp0(action_id, "dismiss") == 0) {
        detailed_action = "app.notificationActionDismiss";
      } else {
        continue;
      }

      const std::string action_payload =
          add_notification_action_to_payload(encoded_payload, action_id);
      g_notification_add_button_with_target_value(
          notification,
          action_title,
          detailed_action,
          g_variant_new_string(action_payload.c_str()));
    }
  }
  g_autofree gchar* notification_id = g_uuid_string_random();
  g_application_send_notification(
      G_APPLICATION(self), notification_id, notification);

  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(TRUE)));
}

static void linux_notifications_method_call_cb(FlMethodChannel* channel,
                                               FlMethodCall* method_call,
                                               gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (strcmp(method, "showNotification") == 0) {
    response = show_linux_notification(self, fl_method_call_get_args(method_call));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static void register_linux_notifications_channel(MyApplication* self,
                                                 FlView* view) {
  FlEngine* engine = fl_view_get_engine(view);
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(engine);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      messenger, kLinuxNotificationsChannel, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      channel, linux_notifications_method_call_cb, self, nullptr);
  self->linux_notifications_channel = FL_METHOD_CHANNEL(g_object_ref(channel));
  if (self->pending_notification_payload != nullptr) {
    dispatch_linux_notification_payload(self, self->pending_notification_payload);
    g_clear_pointer(&self->pending_notification_payload, g_free);
  }
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* existing_window =
      gtk_application_get_active_window(GTK_APPLICATION(application));
  if (existing_window != nullptr) {
    gtk_window_present(existing_window);
    return;
  }

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
    gtk_header_bar_set_title(header_bar, "Rift");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Rift");
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
  register_linux_notifications_channel(self, view);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);
  self->start_hidden = FALSE;
  for (gint i = 1; (*arguments)[i] != nullptr; ++i) {
    if (g_strcmp0((*arguments)[i], "--background") == 0) {
      self->start_hidden = TRUE;
      break;
    }
  }

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
  MyApplication* self = MY_APPLICATION(application);

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);

  GSimpleAction* action = g_simple_action_new(
      kLinuxNotificationActionName, G_VARIANT_TYPE_STRING);
  g_signal_connect(action,
                   "activate",
                   G_CALLBACK(notification_activated_action),
                   self);
  g_action_map_add_action(G_ACTION_MAP(application), G_ACTION(action));
  g_object_unref(action);

  GSimpleAction* open_action = g_simple_action_new(
      kLinuxNotificationActionOpenName, G_VARIANT_TYPE_STRING);
  g_signal_connect(open_action,
                   "activate",
                   G_CALLBACK(notification_button_action),
                   self);
  g_action_map_add_action(G_ACTION_MAP(application), G_ACTION(open_action));
  g_object_unref(open_action);

  GSimpleAction* dismiss_action = g_simple_action_new(
      kLinuxNotificationActionDismissName, G_VARIANT_TYPE_STRING);
  g_signal_connect(dismiss_action,
                   "activate",
                   G_CALLBACK(notification_button_action),
                   self);
  g_action_map_add_action(G_ACTION_MAP(application), G_ACTION(dismiss_action));
  g_object_unref(dismiss_action);
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
  g_clear_object(&self->linux_notifications_channel);
  g_clear_pointer(&self->pending_notification_payload, g_free);
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

static void my_application_init(MyApplication* self) {
  self->linux_notifications_channel = nullptr;
  self->pending_notification_payload = nullptr;
  self->start_hidden = FALSE;
}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_DEFAULT_FLAGS, nullptr));
}
