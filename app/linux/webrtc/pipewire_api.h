// Hanashi: PipeWire's library, loaded when first needed, so that a system
// without it still runs the app: what sharing a screen
// (portal_screen_cast.cc) and its sound (pipewire_app_sound.cc) use of it.
// The rest of PipeWire's API they use is inline, in its headers.

#ifndef HANASHI_PIPEWIRE_API_H_
#define HANASHI_PIPEWIRE_API_H_

#include <dlfcn.h>
#include <pipewire/pipewire.h>

#include <iostream>
#include <type_traits>

namespace hanashi {

struct PipeWireApi {
  void (*init)(int*, char***);
  pw_thread_loop* (*thread_loop_new)(const char*, const spa_dict*);
  pw_loop* (*thread_loop_get_loop)(pw_thread_loop*);
  int (*thread_loop_start)(pw_thread_loop*);
  void (*thread_loop_stop)(pw_thread_loop*);
  void (*thread_loop_lock)(pw_thread_loop*);
  void (*thread_loop_unlock)(pw_thread_loop*);
  void (*thread_loop_destroy)(pw_thread_loop*);
  pw_context* (*context_new)(pw_loop*, pw_properties*, size_t);
  void (*context_destroy)(pw_context*);
  pw_core* (*context_connect)(pw_context*, pw_properties*, size_t);
  pw_core* (*context_connect_fd)(pw_context*, int, pw_properties*, size_t);
  int (*core_disconnect)(pw_core*);
  pw_stream* (*stream_new)(pw_core*, const char*, pw_properties*);
  void (*stream_destroy)(pw_stream*);
  void (*stream_add_listener)(pw_stream*, spa_hook*, const pw_stream_events*, void*);
  int (*stream_connect)(pw_stream*, enum pw_direction, uint32_t, enum pw_stream_flags, const spa_pod**, uint32_t);
  int (*stream_disconnect)(pw_stream*);
  pw_buffer* (*stream_dequeue_buffer)(pw_stream*);
  int (*stream_queue_buffer)(pw_stream*, pw_buffer*);
  int (*stream_update_params)(pw_stream*, const spa_pod**, uint32_t);
  uint32_t (*stream_get_node_id)(pw_stream*);
  void (*proxy_destroy)(pw_proxy*);
  pw_properties* (*properties_new)(const char*, ...);
  void (*properties_free)(pw_properties*);

  // Null without PipeWire, or with one lacking any of the above.
  static const PipeWireApi* Get() {
    static const PipeWireApi* api = Load();
    return api;
  }

 private:
  static const PipeWireApi* Load() {
    void* lib = dlopen("libpipewire-0.3.so.0", RTLD_NOW | RTLD_LOCAL);
    if (lib == nullptr) return nullptr;
    auto* api = new PipeWireApi();
    bool ok = true;
    auto load = [&](auto& field, const char* name) {
      field = reinterpret_cast<std::remove_reference_t<decltype(field)>>(dlsym(lib, name));
      ok = ok && field != nullptr;
    };
    load(api->init, "pw_init");
    load(api->thread_loop_new, "pw_thread_loop_new");
    load(api->thread_loop_get_loop, "pw_thread_loop_get_loop");
    load(api->thread_loop_start, "pw_thread_loop_start");
    load(api->thread_loop_stop, "pw_thread_loop_stop");
    load(api->thread_loop_lock, "pw_thread_loop_lock");
    load(api->thread_loop_unlock, "pw_thread_loop_unlock");
    load(api->thread_loop_destroy, "pw_thread_loop_destroy");
    load(api->context_new, "pw_context_new");
    load(api->context_destroy, "pw_context_destroy");
    load(api->context_connect, "pw_context_connect");
    load(api->context_connect_fd, "pw_context_connect_fd");
    load(api->core_disconnect, "pw_core_disconnect");
    load(api->stream_new, "pw_stream_new");
    load(api->stream_destroy, "pw_stream_destroy");
    load(api->stream_add_listener, "pw_stream_add_listener");
    load(api->stream_connect, "pw_stream_connect");
    load(api->stream_disconnect, "pw_stream_disconnect");
    load(api->stream_dequeue_buffer, "pw_stream_dequeue_buffer");
    load(api->stream_queue_buffer, "pw_stream_queue_buffer");
    load(api->stream_update_params, "pw_stream_update_params");
    load(api->stream_get_node_id, "pw_stream_get_node_id");
    load(api->proxy_destroy, "pw_proxy_destroy");
    load(api->properties_new, "pw_properties_new");
    load(api->properties_free, "pw_properties_free");
    if (!ok) {
      std::cerr << "[hanashi pipewire] libpipewire lacks what is needed" << std::endl;
      delete api;
      return nullptr;
    }
    api->init(nullptr, nullptr);
    return api;
  }
};

}  // namespace hanashi

#endif  // HANASHI_PIPEWIRE_API_H_
